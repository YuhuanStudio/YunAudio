import AudioToolbox
import AVFoundation
import Foundation

/// A knob on a stage.
///
/// Carries its own range and unit so the interface can draw it without knowing
/// anything about the Audio Unit behind it — adding a stage should not mean
/// adding a matching case to a switch in a view.
public struct EffectParameter: Identifiable, Hashable, Sendable {
    public init(
        id: String, title: String, minimum: Float, maximum: Float, unit: String,
        defaultValue: Float, isLogarithmic: Bool, options: [String] = []
    ) {
        self.id = id
        self.title = title
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
        self.defaultValue = defaultValue
        self.isLogarithmic = isLogarithmic
        self.options = options
    }

    public let id: String
    public let title: String
    public let minimum: Float
    public let maximum: Float
    public let unit: String
    public let defaultValue: Float
    /// Log-scaled parameters (frequency) need a curve; the rest are linear.
    public let isLogarithmic: Bool
    /// Named positions, for a parameter that is a choice rather than a
    /// quantity. Empty for an ordinary knob.
    ///
    /// A voice character is not a number anybody can reason about — nobody
    /// wants "ring modulator at 137 Hz", they want "robot" — so the parameter
    /// carries the names and the chain maps each one onto a whole bundle of
    /// unit settings.
    public var options: [String] = []

    public var isChoice: Bool { !options.isEmpty }

    /// Position on a 0…1 slider for a value.
    public func fraction(for value: Float) -> Double {
        guard maximum > minimum else { return 0 }
        if isLogarithmic, minimum > 0 {
            let low = log(Double(minimum))
            let high = log(Double(maximum))
            return (log(Double(max(minimum, value))) - low) / (high - low)
        }
        return Double((value - minimum) / (maximum - minimum))
    }

    /// The value at a position, the inverse of `fraction(for:)`.
    public func value(atFraction fraction: Double) -> Float {
        let clamped = max(0, min(1, fraction))
        if isLogarithmic, minimum > 0 {
            let low = log(Double(minimum))
            let high = log(Double(maximum))
            return Float(exp(low + clamped * (high - low)))
        }
        return minimum + Float(clamped) * (maximum - minimum)
    }

    public func formatted(_ value: Float) -> String {
        if unit == "Hz", value >= 1000 {
            return String(format: "%.1f kHz", value / 1000)
        }
        return unit == "Hz" || abs(value) >= 100
            ? String(format: "%.0f %@", value, unit)
            : String(format: "%.1f %@", value, unit)
    }
}

/// What a stage is *for*, as opposed to where it sits in the signal.
///
/// Not an ordering: the chain is one series and `chainOrder` decides it,
/// whatever the interface does. This is the decision being made. Taking out
/// what should not be there, sounding like somebody else, and shaping what is
/// left are three unrelated intentions, and presenting them as one column of
/// eleven switches made the reader work out which was which every time.
public enum EffectGroup: String, CaseIterable, Sendable, Identifiable {
    /// None of it meant to be heard as an effect.
    case cleanUp
    /// The voice changer, both halves of it.
    case voice
    /// Everything that is meant to be heard.
    case colour

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cleanUp: "Clean up"
        case .voice: "Change the voice"
        case .colour: "Tone and space"
        }
    }

    public var detail: String {
        switch self {
        case .cleanUp:
            "Takes out what should not be there. None of it is meant to be audible as an effect."
        case .voice:
            "Sound like somebody else. Both halves move together, and both cost latency."
        case .colour:
            "Shapes the voice and puts it somewhere. All of this is meant to be heard."
        }
    }
}

/// One stage of the processing chain.
public enum EffectKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case voiceIsolation
    /// A noise gate, built from the dynamics processor's expander.
    ///
    /// Razer's own is host-side — the device module has no gate function at
    /// all, and the slider in Synapse drives a THX processing object on the PC.
    /// So there is nothing to send a microphone and this is ours to write.
    case gate
    /// Kept as `equaliser` in the stored form because that is what shipped
    /// preferences call it; it has only ever been a high-pass.
    case equaliser
    /// Six fixed bands across the voice.
    ///
    /// The most conspicuous gap in the whole application for a long time: there
    /// was a high-pass and nothing else, so a boxy room or a harsh sibilance
    /// had no answer at all. Fixed frequencies rather than a parametric sweep
    /// because they line up with the bands of the analyser above — you can see
    /// the problem and reach for the control under it.
    case tone
    case compressor
    /// Pitch shift with the speed left alone.
    ///
    /// Half of a voice changer, and on its own the disappointing half: moving
    /// pitch without touching anything else is what makes somebody sound like a
    /// chipmunk rather than like a different person. The other half is the
    /// character below.
    case pitch
    /// Ring modulation, decimation and soft clipping — the machinery behind
    /// every robot, radio and monster voice there has ever been.
    case character
    /// Moves the resonances of the voice without moving its pitch.
    ///
    /// The half of a voice change that decides whether it sounds like a
    /// different person or like a chipmunk, and the only stage here that is not
    /// a hosted Audio Unit — nothing on the system does it, so it is written
    /// out in `FormantShifter`.
    case formant
    /// A room around the voice. The thing a karaoke box sells.
    case reverb
    /// Repeats. The other half of that same box.
    case echo
    case limiter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voiceIsolation: "Voice isolation"
        case .gate: "Noise gate"
        case .equaliser: "High-pass"
        case .tone: "Equaliser"
        case .compressor: "Compressor"
        case .pitch: "Pitch"
        case .character: "Character"
        case .formant: "Formants"
        case .reverb: "Reverb"
        case .echo: "Echo"
        case .limiter: "Limiter"
        }
    }

    public var detail: String {
        switch self {
        case .voiceIsolation: "Apple's on-device model. Adds about 56 ms."
        case .gate:
            "Turns the signal down when nothing is being said. Cheaper than voice "
                + "isolation and it leaves speech untouched."
        case .equaliser: "Removes rumble below the voice. It has never been more than this."
        case .tone:
            "Six bands across the voice, at the frequencies the analyser draws — "
                + "so what you can see, you can reach."
        case .compressor: "Evens out level. Useful before a limiter, not instead of one."
        case .pitch:
            "Moves the voice up or down without changing its speed. Costs latency, "
                + "and enough of a shift stops sounding like a person."
        case .character:
            "Robot, radio, monster. Pitch alone only makes somebody sound small; "
                + "this is what makes them sound like something else."
        case .formant:
            "Moves the resonances of the voice without moving its pitch. This is "
                + "what turns a shift into a different person rather than a chipmunk."
        case .reverb:
            "Puts the voice in a room. Small amounts flatter it; large amounts hide it."
        case .echo: "Repeats. Musical in small doses, unusable on a call in large ones."
        case .limiter: "Stops the signal exceeding full scale. Cheap insurance."
        }
    }

    /// Which of the three jobs this stage is doing.
    ///
    /// Exhaustive rather than defaulted, so a stage added later has to be
    /// placed rather than quietly landing in whichever group the `default`
    /// happened to name.
    public var group: EffectGroup {
        switch self {
        case .voiceIsolation, .equaliser, .gate, .compressor, .limiter: .cleanUp
        case .pitch, .formant, .character: .voice
        case .tone, .reverb, .echo: .colour
        }
    }

    /// The stages of one group, in the order the signal meets them.
    ///
    /// Signal order rather than declaration order even inside a group, because
    /// the reader is looking at a chain: a compressor listed above the gate
    /// that feeds it would describe something the engine never builds.
    public static func stages(in group: EffectGroup) -> [EffectKind] {
        allCases.filter { $0.group == group }.sorted { $0.chainOrder < $1.chainOrder }
    }

    /// The voices the character stage can put on.
    ///
    /// Each is a bundle of settings on one distortion unit rather than a
    /// separate effect, because that unit already contains a ring modulator, a
    /// decimator and a soft clipper — which between them are what every robot,
    /// radio and monster voice has ever been made of.
    public enum Flavour: Int, CaseIterable, Sendable {
        /// Ring modulation at a low frequency: the classic robot.
        case robot
        /// Bandwidth thrown away and clipped: a bad connection.
        case radio
        /// Heavy soft clipping with a slow modulator under it.
        case monster
        /// Sample rate and word length destroyed on purpose.
        case bitcrush
        /// Two ring modulators slightly apart, beating against each other.
        case alien

        public var title: String {
            switch self {
            case .robot: "Robot"
            case .radio: "Radio"
            case .monster: "Monster"
            case .bitcrush: "Bitcrush"
            case .alien: "Alien"
            }
        }
    }

    /// The knobs this stage offers, with the ranges the underlying unit accepts.
    public var parameters: [EffectParameter] {
        switch self {
        case .voiceIsolation:
            [
                EffectParameter(
                    id: "mix", title: "Amount", minimum: 0, maximum: 100,
                    unit: "%", defaultValue: 100, isLogarithmic: false)
            ]
        case .gate:
            [
                EffectParameter(
                    id: "threshold", title: "Opens above", minimum: -80, maximum: -10,
                    unit: "dB", defaultValue: -45, isLogarithmic: false),
                EffectParameter(
                    id: "ratio", title: "Depth", minimum: 1, maximum: 50,
                    unit: ":1", defaultValue: 20, isLogarithmic: true),
                EffectParameter(
                    id: "release", title: "Release", minimum: 20, maximum: 1000,
                    unit: "ms", defaultValue: 200, isLogarithmic: true),
            ]
        case .equaliser:
            [
                EffectParameter(
                    id: "frequency", title: "Corner", minimum: 20, maximum: 500,
                    unit: "Hz", defaultValue: 80, isLogarithmic: true)
            ]
        case .tone:
            Self.toneBands.map { band in
                EffectParameter(
                    id: "b\(band.index)", title: band.title, minimum: -12, maximum: 12,
                    unit: "dB", defaultValue: 0, isLogarithmic: false)
            }
        case .compressor:
            [
                EffectParameter(
                    id: "threshold", title: "Threshold", minimum: -40, maximum: 0,
                    unit: "dB", defaultValue: -20, isLogarithmic: false),
                EffectParameter(
                    id: "headroom", title: "Headroom", minimum: 0.1, maximum: 20,
                    unit: "dB", defaultValue: 5, isLogarithmic: false),
            ]
        case .pitch:
            [
                // Cents rather than semitones, because a convincing shift is
                // rarely a whole number of them — a couple of semitones down is
                // a different person, twelve is a cartoon.
                EffectParameter(
                    id: "cents", title: "Shift", minimum: -1200, maximum: 1200,
                    unit: "cents", defaultValue: 0, isLogarithmic: false)
            ]
        case .formant:
            [
                EffectParameter(
                    // Percent rather than a bare ratio, because a control that
                    // reads 1.2 tells nobody anything and one that reads +20%
                    // tells them which way it goes.
                    id: "shift", title: "Resonance", minimum: -40, maximum: 60,
                    unit: "%", defaultValue: 0, isLogarithmic: false)
            ]
        case .character:
            [
                EffectParameter(
                    id: "flavour", title: "Voice type", minimum: 0,
                    maximum: Float(Flavour.allCases.count - 1), unit: "",
                    defaultValue: 0, isLogarithmic: false,
                    options: Flavour.allCases.map(\.title)),
                EffectParameter(
                    id: "amount", title: "Amount", minimum: 0, maximum: 100,
                    unit: "%", defaultValue: 60, isLogarithmic: false),
            ]
        case .reverb:
            [
                EffectParameter(
                    id: "mix", title: "Amount", minimum: 0, maximum: 100,
                    unit: "%", defaultValue: 18, isLogarithmic: false),
                EffectParameter(
                    id: "decay", title: "Size", minimum: 0.1, maximum: 8,
                    unit: "s", defaultValue: 1.2, isLogarithmic: true),
            ]
        case .echo:
            [
                EffectParameter(
                    id: "mix", title: "Amount", minimum: 0, maximum: 100,
                    unit: "%", defaultValue: 20, isLogarithmic: false),
                EffectParameter(
                    id: "time", title: "Time", minimum: 10, maximum: 800,
                    unit: "ms", defaultValue: 180, isLogarithmic: true),
                EffectParameter(
                    id: "feedback", title: "Repeats", minimum: 0, maximum: 80,
                    unit: "%", defaultValue: 25, isLogarithmic: false),
            ]
        case .limiter:
            [
                EffectParameter(
                    id: "gain", title: "Pre-gain", minimum: -20, maximum: 20,
                    unit: "dB", defaultValue: 0, isLogarithmic: false)
            ]
        }
    }

    /// Not every one of these is an effect as CoreAudio classifies them.
    ///
    /// `NewTimePitch` is a format converter, because changing pitch without
    /// changing duration is formally a rate conversion. Looking for it under
    /// `kAudioUnitType_Effect` finds nothing at all, and the stage would
    /// silently not appear in the chain.
    var componentType: OSType {
        switch self {
        case .pitch: kAudioUnitType_FormatConverter
        case .formant: 0
        default: kAudioUnitType_Effect
        }
    }

    /// True when this stage is written here rather than hosted.
    ///
    /// Only one, and it is the one nothing on the system provides. Every other
    /// stage is Apple's own unit, which is the right trade every time it is
    /// available: their limiter is better than one written in an afternoon.
    var isNative: Bool { self == .formant }

    var subType: OSType {
        switch self {
        case .voiceIsolation: SoundIsolation.componentSubType
        case .gate: kAudioUnitSubType_DynamicsProcessor
        case .equaliser: kAudioUnitSubType_NBandEQ
        case .tone: kAudioUnitSubType_NBandEQ
        case .compressor: kAudioUnitSubType_DynamicsProcessor
        case .pitch: kAudioUnitSubType_NewTimePitch
        // Not a hosted unit at all; the subtype is never consulted for it.
        case .formant: 0
        case .character: kAudioUnitSubType_Distortion
        case .reverb: kAudioUnitSubType_Reverb2
        case .echo: kAudioUnitSubType_Delay
        case .limiter: kAudioUnitSubType_PeakLimiter
        }
    }

    /// Effects are ordered by what makes sense signal-wise regardless of the
    /// order they were switched on: isolate, then shape, then control level,
    /// then catch anything left over. A limiter ahead of a compressor is a
    /// configuration mistake the UI should not let happen.
    var chainOrder: Int {
        switch self {
        case .voiceIsolation: 0
        // Ahead of the high-pass on purpose: gating first would key the gate
        // off rumble the high-pass is about to remove, and hold it open on
        // noise nobody can hear.
        case .equaliser: 1
        // After the high-pass and before the gate: shaping tone above the
        // rumble is the point, and gating a signal that is about to be
        // equalised would key the gate off frequencies about to be removed.
        case .tone: 2
        case .gate: 3
        // After the gate: shifting first would move the noise floor along with
        // the voice and give the gate a moving target.
        case .pitch: 4
        // Directly after the pitch shift and before anything else: the two are
        // one effect as far as a listener is concerned, and putting a
        // compressor between them would make the character depend on how loud
        // somebody happened to be.
        case .formant: 5
        // After both, so the character is applied to the voice as it is going
        // to be heard rather than as it arrived.
        case .character: 6
        case .compressor: 7
        // The room goes on after the level has been evened out, or the reverb
        // tail gets compressed along with the voice and breathes.
        case .echo: 8
        case .reverb: 9
        // Always last. Anything after a limiter can put the signal back over
        // full scale, which is the one thing it was there to prevent.
        case .limiter: 10
        }
    }

    /// The bands the equaliser offers.
    ///
    /// Six, at frequencies that line up with what the analyser draws and with
    /// what actually goes wrong in a voice: chest, boxiness, the hollow, the
    /// nasal, presence, and air.
    public static let toneBands: [(index: Int, hertz: Float, title: String, isShelf: Bool)] = [
        (0, 80, "Chest", true),
        (1, 250, "Boxiness", false),
        (2, 600, "Hollow", false),
        (3, 1600, "Nasal", false),
        (4, 4000, "Presence", false),
        (5, 10000, "Air", true),
    ]
}

/// A series of Audio Units rendered on the IO thread.
///
/// Each stage pulls from the previous one through a render callback, which is
/// how Audio Units are meant to be chained — the alternative, rendering each
/// into a scratch buffer by hand, means one more copy per stage and no benefit.
final class EffectChain {
    /// What owns one hosted unit.
    ///
    /// Kept beside the instance rather than in a parallel list: inserting a
    /// plugin before the limiter used to move only `units`, so every built-in
    /// lookup from the limiter onwards reached somebody else's unit.
    enum UnitOwner: Equatable {
        case stage(EffectKind)
        case plugin(String)
    }

    private struct HostedUnit {
        let owner: UnitOwner
        let instance: AudioComponentInstance
    }

    /// Buffer the first stage pulls from. The IOProc fills it before rendering.
    let inputBuffer: UnsafeMutablePointer<Float>
    let outputBuffer: UnsafeMutablePointer<Float>
    let maximumFrames: Int

    private(set) var stages: [EffectKind] = []
    private var units: [HostedUnit] = []
    /// The one stage written here rather than hosted, and where it sits in the
    /// run of units.
    private var native: FormantShifter?
    private var nativeIndex: Int?
    /// What the first half of the chain produced when a hosted stage follows
    /// the native one.
    ///
    /// A native tail renders directly into `outputBuffer`; allocating and
    /// copying through this buffer there spent one whole block for no consumer.
    private var nativeBuffer: UnsafeMutablePointer<Float>?
    private var nativeList: UnsafeMutableAudioBufferListPointer?
    private var nativeTimestamp = AudioTimeStamp()
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private var timestamp = AudioTimeStamp()

    /// Total latency the chain adds, in frames.
    private(set) var latencyFrames = 0

    /// Third-party units in the chain, in the order given.
    private(set) var plugins: [AudioUnitPlugin] = []
    /// Plugins that would not load, each with the step that refused and the
    /// status it returned, so the interface can say why rather than only that.
    private(set) var pluginFailures: [AudioUnitLoadFailure] = []
    /// The same list by name alone.
    var failedPlugins: [String] { pluginFailures.map(\.name) }

    /// Plugins are the final shaping stage but never the final safety stage.
    ///
    /// Pure so the ownership layout can be asserted without loading somebody
    /// else's code on the test machine.
    static func pluginInsertionIndex(in owners: [UnitOwner]) -> Int {
        owners.firstIndex(of: .stage(.limiter)) ?? owners.count
    }

    /// Finds an owner without assuming stages and plugins occupy separate
    /// index spaces.
    static func unitIndex<Element>(
        ownedBy owner: UnitOwner, in elements: [Element],
        ownerOf: (Element) -> UnitOwner
    ) -> Int? {
        elements.firstIndex { ownerOf($0) == owner }
    }

    /// The instance owned by one stage or plugin.
    private func unit(ownedBy owner: UnitOwner) -> AudioComponentInstance? {
        guard
            let index = Self.unitIndex(
                ownedBy: owner, in: units, ownerOf: { $0.owner })
        else { return nil }
        return units[index].instance
    }

    convenience init?(kinds: [EffectKind], sampleRate: Double, maximumFrames: Int) {
        self.init(
            kinds: kinds, plugins: [], sampleRate: sampleRate,
            maximumFrames: maximumFrames)
    }

    init?(
        kinds: [EffectKind], plugins requested: [AudioUnitPlugin], sampleRate: Double,
        maximumFrames: Int
    ) {
        guard !kinds.isEmpty || !requested.isEmpty else { return nil }
        self.maximumFrames = maximumFrames
        let requestedStages = kinds.sorted { $0.chainOrder < $1.chainOrder }
        plugins = requested

        inputBuffer = .allocate(capacity: maximumFrames)
        inputBuffer.initialize(repeating: 0, count: maximumFrames)
        outputBuffer = .allocate(capacity: maximumFrames)
        outputBuffer.initialize(repeating: 0, count: maximumFrames)
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(maximumFrames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(outputBuffer))

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        // Hosted stages become units; the native one does not, and its
        // position among them is remembered so the chain can be split around
        // it. Everything before it pulls from the staging buffer as before;
        // everything after pulls from what the native stage produced.
        for kind in requestedStages {
            if kind.isNative {
                nativeIndex = units.count
                native = FormantShifter(sampleRate: sampleRate)
                guard native != nil else { return nil }
                stages.append(kind)
                continue
            }
            var description = AudioComponentDescription(
                componentType: kind.componentType,
                componentSubType: kind.subType,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { continue }
            var instance: AudioComponentInstance?
            guard AudioComponentInstanceNew(component, &instance) == noErr,
                let unit = instance
            else { continue }

            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &format, formatSize)
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                &format, formatSize)
            var frames = UInt32(maximumFrames)
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &frames, UInt32(MemoryLayout<UInt32>.size))
            units.append(HostedUnit(owner: .stage(kind), instance: unit))
            stages.append(kind)
        }

        // Third-party units go in one place, and it is not arbitrary: after
        // everything this application shapes, and before the limiter. The
        // limiter's whole job is that nothing downstream ever sees a sample it
        // has to clip, and anything running after it can put the signal back
        // over full scale — so a plugin cannot be allowed there whatever the
        // user drags around. Everywhere else in the chain is a matter of taste
        // and this is not.
        if !plugins.isEmpty {
            let insertAt = Self.pluginInsertionIndex(in: units.map(\.owner))
            var built: [HostedUnit] = []
            for plugin in plugins {
                var description = plugin.componentDescription
                guard let component = AudioComponentFindNext(nil, &description) else {
                    pluginFailures.append(
                        .init(name: plugin.name, reason: .notInstalled, status: noErr))
                    continue
                }
                var instance: AudioComponentInstance?
                let created = AudioComponentInstanceNew(component, &instance)
                guard created == noErr, let unit = instance else {
                    pluginFailures.append(
                        .init(
                            name: plugin.name, reason: .couldNotInstantiate, status: created))
                    continue
                }

                // Somebody else's unit is vetted here rather than trusted to
                // the common initialise below, and the reason is not tidiness.
                // The chain is mono, and a stereo-only unit answers
                // kAudioUnitErr_FormatNotSupported to both of these and then
                // refuses to initialise — at which point the common loop tears
                // the whole chain down. One rejected plugin took the gate, the
                // equaliser, the compressor and the limiter with it, and named
                // none of them. AUAudioMix is the measurable case: -10868 to
                // each format, -10875 to initialise.
                let inputFormat = AudioUnitSetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                    &format, formatSize)
                let outputFormat = AudioUnitSetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                    &format, formatSize)
                guard inputFormat == noErr, outputFormat == noErr else {
                    pluginFailures.append(
                        .init(
                            name: plugin.name, reason: .formatRejected,
                            status: inputFormat == noErr ? outputFormat : inputFormat))
                    AudioComponentInstanceDispose(unit)
                    continue
                }
                // Before initialising, never after: a unit reads this when it
                // sizes its internal buffers, and setting it afterwards is
                // either refused or ignored depending on whose unit it is.
                var frames = UInt32(maximumFrames)
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global, 0, &frames,
                    UInt32(MemoryLayout<UInt32>.size))

                // A dry run, undone immediately. Initialising here proves the
                // unit can start on its own terms; the common loop below then
                // starts it for real once it is connected, which is the state
                // it will render in.
                let started = AudioUnitInitialize(unit)
                guard started == noErr else {
                    pluginFailures.append(
                        .init(
                            name: plugin.name, reason: .wouldNotInitialise, status: started))
                    AudioComponentInstanceDispose(unit)
                    continue
                }
                AudioUnitUninitialize(unit)

                built.append(HostedUnit(owner: .plugin(plugin.id), instance: unit))
            }
            if !built.isEmpty {
                units.insert(contentsOf: built, at: insertAt)
                // The native stage's position is an index into `units`, so
                // inserting ahead of it moves it.
                if let native = nativeIndex, native >= insertAt {
                    nativeIndex = native + built.count
                }
            }
        }

        // A chain of nothing but the native stage is legitimate: somebody who
        // wants only a formant shift should get one.
        //
        // Nothing is freed on the way out of a failed init, here or below.
        // Swift runs `deinit` on a class whose failable init returns nil once
        // every stored property has a value, so cleaning up here as well freed
        // the same three allocations twice and libmalloc aborted the process:
        // POINTER_BEING_FREED_WAS_NOT_ALLOCATED, inside EffectChain.deinit,
        // reached from EffectChain.init. It was not a plugin failing to load —
        // it was the application dying on the spot.
        guard !units.isEmpty || native != nil else { return nil }

        if native != nil {
            nativeTimestamp.mFlags = .sampleTimeValid
        }
        if let nativeIndex, nativeIndex < units.count {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)
            buffer.initialize(repeating: 0, count: maximumFrames)
            nativeBuffer = buffer
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            list[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maximumFrames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buffer))
            nativeList = list
        }

        // The head pulls from our staging buffer; every later stage pulls from
        // the one before it.
        let headCallback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData in
                guard let ioData else { return noErr }
                let source = refCon.assumingMemoryBound(to: Float.self)
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                for index in 0..<buffers.count {
                    guard let data = buffers[index].mData else { continue }
                    data.assumingMemoryBound(to: Float.self)
                        .update(from: source, count: Int(frameCount))
                }
                return noErr
            },
            inputProcRefCon: UnsafeMutableRawPointer(inputBuffer))
        if !units.isEmpty {
            // When the native stage is first, unit zero is already after the
            // split. Pointing it at `inputBuffer` bypassed the formant output:
            // a formant followed by only the limiter rendered both stages but
            // the listener heard the limiter over the unshifted input.
            var firstCallback = headCallback
            if nativeIndex == 0, let nativeBuffer {
                firstCallback.inputProcRefCon = UnsafeMutableRawPointer(nativeBuffer)
            }
            AudioUnitSetProperty(
                units[0].instance, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0,
                &firstCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }

        for index in 1..<max(units.count, 1) where index < units.count {
            // The unit immediately after the native stage is fed from the
            // native stage's buffer rather than connected to the unit before
            // it — that connection is where the split goes.
            if index == nativeIndex, let buffer = nativeBuffer {
                var callback = AURenderCallbackStruct(
                    inputProc: headCallback.inputProc,
                    inputProcRefCon: UnsafeMutableRawPointer(buffer))
                AudioUnitSetProperty(
                    units[index].instance, kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input, 0,
                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
                continue
            }
            var connection = AudioUnitConnection(
                sourceAudioUnit: units[index - 1].instance,
                sourceOutputNumber: 0,
                destInputNumber: 0)
            AudioUnitSetProperty(
                units[index].instance, kAudioUnitProperty_MakeConnection,
                kAudioUnitScope_Input, 0,
                &connection, UInt32(MemoryLayout<AudioUnitConnection>.size))
        }

        for unit in units where AudioUnitInitialize(unit.instance) != noErr {
            // A stage that will not initialise is worse than no chain: the
            // signal would silently skip it while the UI claimed it was on.
            // Only this application's own stages can reach here now — a
            // third-party unit that cannot start was rejected and named above,
            // rather than taking every other stage down with it.
            teardown()
            return nil
        }

        latencyFrames = (native?.latencyFrames ?? 0)
        latencyFrames += units.reduce(into: 0) { total, unit in
            var latency: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            AudioUnitGetProperty(
                unit.instance, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
                &latency, &size)
            total += Int(latency * sampleRate)
        }

        applyDefaults(sampleRate: sampleRate)
        timestamp.mFlags = .sampleTimeValid
    }

    deinit {
        teardown()
        inputBuffer.deallocate()
        outputBuffer.deallocate()
        nativeBuffer?.deallocate()
        if let nativeList { free(nativeList.unsafeMutablePointer) }
        free(bufferList.unsafeMutablePointer)
    }

    private func teardown() {
        for unit in units {
            AudioUnitUninitialize(unit.instance)
            AudioComponentInstanceDispose(unit.instance)
        }
        units.removeAll()
    }

    /// Starting points chosen for a voice signal rather than the units' own
    /// defaults, which are tuned for music.
    private func applyDefaults(sampleRate: Double) {
        for hosted in units {
            guard case .stage(let kind) = hosted.owner else { continue }
            let unit = hosted.instance
            switch kind {
            case .voiceIsolation:
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                    kAudioUnitScope_Global, 0, 100, 0)
            case .gate:
                // The dynamics processor does both jobs; a gate is its expander
                // with the compressor half left alone. The compression side is
                // pushed out of the way rather than merely unset — its own
                // defaults are tuned for music and would squash speech.
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_ExpansionThreshold,
                    kAudioUnitScope_Global, 0, -45, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_ExpansionRatio,
                    kAudioUnitScope_Global, 0, 20, 0)
                // Fast enough not to clip the start of a word, slow enough not
                // to chatter on breath between them.
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_AttackTime,
                    kAudioUnitScope_Global, 0, 0.002, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_ReleaseTime,
                    kAudioUnitScope_Global, 0, 0.2, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_Threshold,
                    kAudioUnitScope_Global, 0, 0, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_OverallGain,
                    kAudioUnitScope_Global, 0, 0, 0)
            case .equaliser:
                // A high-pass at 80 Hz: everything below is rumble, handling
                // noise and plosive energy, none of it voice.
                var bands: UInt32 = 1
                AudioUnitSetProperty(
                    unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0,
                    &bands, UInt32(MemoryLayout<UInt32>.size))
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUNBandEQParam_FilterType),
                    kAudioUnitScope_Global, 0,
                    // Butterworth rather than resonant: a resonant high-pass
                    // adds a peak right where the plosive energy is.
                    Float(kAUNBandEQFilterType_2ndOrderButterworthHighPass), 0)
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUNBandEQParam_Frequency),
                    kAudioUnitScope_Global, 0, 80, 0)
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUNBandEQParam_BypassBand),
                    kAudioUnitScope_Global, 0, 0, 0)
            case .tone:
                var bands = UInt32(EffectKind.toneBands.count)
                AudioUnitSetProperty(
                    unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0,
                    &bands, UInt32(MemoryLayout<UInt32>.size))
                for band in EffectKind.toneBands {
                    let offset = AudioUnitParameterID(band.index)
                    AudioUnitSetParameter(
                        unit, AudioUnitParameterID(kAUNBandEQParam_FilterType) + offset,
                        kAudioUnitScope_Global, 0,
                        // Shelves at the ends and bells in between, which is
                        // what every voice equaliser has ever been: the top and
                        // bottom bands are asked to move everything past them,
                        // and a bell there would leave the extremes untouched.
                        Float(
                            band.isShelf
                                ? (band.index == 0
                                    ? kAUNBandEQFilterType_LowShelf
                                    : kAUNBandEQFilterType_HighShelf)
                                : kAUNBandEQFilterType_Parametric), 0)
                    AudioUnitSetParameter(
                        unit, AudioUnitParameterID(kAUNBandEQParam_Frequency) + offset,
                        kAudioUnitScope_Global, 0, band.hertz, 0)
                    AudioUnitSetParameter(
                        unit, AudioUnitParameterID(kAUNBandEQParam_Gain) + offset,
                        kAudioUnitScope_Global, 0, 0, 0)
                    // Two thirds of an octave: wide enough not to sound like a
                    // notch, narrow enough that two neighbouring bands do not
                    // simply add up.
                    AudioUnitSetParameter(
                        unit, AudioUnitParameterID(kAUNBandEQParam_Bandwidth) + offset,
                        kAudioUnitScope_Global, 0, 0.66, 0)
                    AudioUnitSetParameter(
                        unit, AudioUnitParameterID(kAUNBandEQParam_BypassBand) + offset,
                        kAudioUnitScope_Global, 0, 0, 0)
                }
            case .compressor:
                // Gentle: 3:1 above -20 dBFS. A router should even out a voice,
                // not squash it — the conferencing application will apply its
                // own dynamics after this.
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -20, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 5, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.01, 0
                )
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.15,
                    0)
            case .pitch:
                // Unshifted by default. Switching the stage on has to be
                // inaudible until somebody moves the control — a voice changer
                // that changes the voice the moment it is enabled gives no way
                // to hear what it cost in latency alone.
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kNewTimePitchParam_Pitch),
                    kAudioUnitScope_Global, 0, 0, 0)
                // Rate is left at one throughout: this is a pitch shifter, not
                // a speed control, and anything other than one would put the
                // output out of step with the clock the whole router is locked
                // to.
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kNewTimePitchParam_Rate),
                    kAudioUnitScope_Global, 0, 1, 0)
            case .formant:
                // Never reached: the native stage produces no unit and is not
                // a `HostedUnit`. Stated rather than left to `default`, so that
                // adding another native stage fails to compile here instead
                // of silently configuring the wrong unit.
                break
            case .character:
                applyFlavour(.robot, amount: 60, to: unit)
            case .reverb:
                // Small and short. The unit's own default is a concert hall,
                // which on a voice call sounds like a fault rather than an
                // effect.
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kReverb2Param_DryWetMix),
                    kAudioUnitScope_Global, 0, 18, 0)
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kReverb2Param_DecayTimeAt0Hz),
                    kAudioUnitScope_Global, 0, 1.2, 0)
                // The top decays faster than the bottom in every real room, and
                // a tail that stays bright is the single thing that makes a
                // reverb sound artificial.
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kReverb2Param_DecayTimeAtNyquist),
                    kAudioUnitScope_Global, 0, 0.6, 0)
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kReverb2Param_MinDelayTime),
                    kAudioUnitScope_Global, 0, 0.008, 0)
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kReverb2Param_MaxDelayTime),
                    kAudioUnitScope_Global, 0, 0.05, 0)
            case .echo:
                AudioUnitSetParameter(
                    unit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 20, 0)
                AudioUnitSetParameter(
                    unit, kDelayParam_DelayTime, kAudioUnitScope_Global, 0, 0.18, 0)
                AudioUnitSetParameter(
                    unit, kDelayParam_Feedback, kAudioUnitScope_Global, 0, 25, 0)
                // Repeats get duller each time, as they do off a real wall.
                // Without this the tail stays as bright as the source and reads
                // as a fault.
                AudioUnitSetParameter(
                    unit, kDelayParam_LopassCutoff, kAudioUnitScope_Global, 0, 6000, 0)
            case .limiter:
                // Just below full scale, so nothing downstream ever sees a
                // sample it has to clip.
                AudioUnitSetParameter(
                    unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
                AudioUnitSetParameter(
                    unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
                AudioUnitSetParameter(
                    unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
            }
        }
    }

    /// Puts one voice on the distortion unit.
    ///
    /// The unit is a bag of independent processes — a ring modulator, a
    /// decimator, a soft clipper, a short delay — and the interesting part is
    /// not any one of them but which combination sounds like a thing. Every
    /// process not wanted by a flavour is explicitly zeroed rather than left
    /// alone, because the unit keeps whatever the last flavour set and the
    /// leftovers are what make a robot and a radio sound like the same mess.
    private func applyFlavour(
        _ flavour: EffectKind.Flavour, amount: Float, to unit: AudioComponentInstance
    ) {
        func set(_ parameter: AudioUnitParameterID, _ value: Float) {
            AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0)
        }

        // Everything off first.
        set(AudioUnitParameterID(kDistortionParam_Delay), 0.1)
        set(AudioUnitParameterID(kDistortionParam_Decay), 0)
        set(AudioUnitParameterID(kDistortionParam_DelayMix), 0)
        set(AudioUnitParameterID(kDistortionParam_Decimation), 0)
        set(AudioUnitParameterID(kDistortionParam_Rounding), 0)
        set(AudioUnitParameterID(kDistortionParam_PolynomialMix), 0)
        set(AudioUnitParameterID(kDistortionParam_RingModFreq1), 100)
        set(AudioUnitParameterID(kDistortionParam_RingModFreq2), 100)
        set(AudioUnitParameterID(kDistortionParam_RingModBalance), 50)
        set(AudioUnitParameterID(kDistortionParam_RingModMix), 0)
        set(AudioUnitParameterID(kDistortionParam_SoftClipGain), -6)
        set(AudioUnitParameterID(kDistortionParam_FinalMix), amount)

        switch flavour {
        case .robot:
            // A single modulator low enough to be heard as a pitch rather than
            // as noise. Above about 300 Hz it stops sounding mechanical and
            // starts sounding broken.
            set(AudioUnitParameterID(kDistortionParam_RingModFreq1), 130)
            set(AudioUnitParameterID(kDistortionParam_RingModMix), 90)
            set(AudioUnitParameterID(kDistortionParam_RingModBalance), 100)
        case .radio:
            // Not a filter — this unit has none — but decimation plus a little
            // clipping gives the same impression of a signal that has been
            // through something narrow.
            set(AudioUnitParameterID(kDistortionParam_Decimation), 35)
            set(AudioUnitParameterID(kDistortionParam_Rounding), 20)
            set(AudioUnitParameterID(kDistortionParam_SoftClipGain), 6)
            set(AudioUnitParameterID(kDistortionParam_PolynomialMix), 40)
        case .monster:
            // Heavy clipping is what makes something sound large; the slow
            // modulator underneath adds the growl. Pair it with the pitch stage
            // a few semitones down for the full effect — the two are separate
            // on purpose, because a character that also moved pitch could not
            // be used on a voice that was already being shifted.
            set(AudioUnitParameterID(kDistortionParam_SoftClipGain), 20)
            set(AudioUnitParameterID(kDistortionParam_PolynomialMix), 70)
            set(AudioUnitParameterID(kDistortionParam_RingModFreq1), 40)
            set(AudioUnitParameterID(kDistortionParam_RingModMix), 25)
        case .bitcrush:
            set(AudioUnitParameterID(kDistortionParam_Decimation), 70)
            set(AudioUnitParameterID(kDistortionParam_Rounding), 65)
        case .alien:
            // Two modulators a little apart beat against each other, which is
            // what stops it sounding like a single steady tone.
            set(AudioUnitParameterID(kDistortionParam_RingModFreq1), 220)
            set(AudioUnitParameterID(kDistortionParam_RingModFreq2), 275)
            set(AudioUnitParameterID(kDistortionParam_RingModBalance), 50)
            set(AudioUnitParameterID(kDistortionParam_RingModMix), 85)
            set(AudioUnitParameterID(kDistortionParam_Decimation), 15)
        }
    }

    /// The flavour each character stage is currently wearing, so changing the
    /// amount does not reset the voice.
    private var flavours: [EffectKind: EffectKind.Flavour] = [:]
    private var amounts: [EffectKind: Float] = [:]

    /// The character stage's current voice and depth, for tests and for the
    /// interface to read back rather than assume.
    struct CharacterState: Equatable {
        let flavour: EffectKind.Flavour
        let amount: Float
    }

    var characterState: CharacterState? {
        guard stages.contains(.character) else { return nil }
        return CharacterState(
            flavour: flavours[.character] ?? .robot, amount: amounts[.character] ?? 60)
    }

    /// True when this stage knows what to do with that knob.
    ///
    /// The setter is deliberately silent about pairs it does not recognise, so
    /// that a preferences file naming a knob that no longer exists loads rather
    /// than crashes. That silence also means a control the interface offers and
    /// the chain forgot to wire would move and do nothing, with no way to tell
    /// from either side — which is what this exists to catch.
    func recognises(_ parameter: String, of kind: EffectKind) -> Bool {
        Self.knownParameters.contains(Pair(kind: kind, parameter: parameter))
    }

    private struct Pair: Hashable {
        let kind: EffectKind
        let parameter: String
    }

    private static let knownParameters: Set<Pair> = [
        Pair(kind: .voiceIsolation, parameter: "mix"),
        Pair(kind: .gate, parameter: "threshold"),
        Pair(kind: .gate, parameter: "ratio"),
        Pair(kind: .gate, parameter: "release"),
        Pair(kind: .equaliser, parameter: "frequency"),
        Pair(kind: .tone, parameter: "b0"),
        Pair(kind: .tone, parameter: "b1"),
        Pair(kind: .tone, parameter: "b2"),
        Pair(kind: .tone, parameter: "b3"),
        Pair(kind: .tone, parameter: "b4"),
        Pair(kind: .tone, parameter: "b5"),
        Pair(kind: .compressor, parameter: "threshold"),
        Pair(kind: .compressor, parameter: "headroom"),
        Pair(kind: .pitch, parameter: "cents"),
        Pair(kind: .character, parameter: "flavour"),
        Pair(kind: .character, parameter: "amount"),
        Pair(kind: .formant, parameter: "shift"),
        Pair(kind: .reverb, parameter: "mix"),
        Pair(kind: .reverb, parameter: "decay"),
        Pair(kind: .echo, parameter: "mix"),
        Pair(kind: .echo, parameter: "time"),
        Pair(kind: .echo, parameter: "feedback"),
        Pair(kind: .limiter, parameter: "gain"),
    ]

    /// Applies a knob to the live unit. Audio Unit parameter changes are
    /// realtime-safe by design, so this needs no queue of its own.
    /// Sets a parameter on a third-party unit.
    ///
    /// Separate from the built-in setter because there is nothing to switch on:
    /// the parameter is whatever the plugin's author called it, and the only
    /// description of it is the one the unit handed out at runtime.
    func set(_ parameter: String, ofPlugin id: String, to value: Float) {
        guard let unit = unit(ownedBy: .plugin(id)),
            let identifier = AudioUnitPlugins.parameterID(from: parameter)
        else { return }
        AudioUnitSetParameter(unit, identifier, kAudioUnitScope_Global, 0, value, 0)
    }

    /// How much a stage is currently pulling the signal down, in decibels.
    ///
    /// Every compressor ever shipped has this meter, and for one reason: a
    /// compressor with the threshold set wrong is completely silent about it.
    /// It sounds like a compressor doing nothing, which is exactly what it is,
    /// and the only way to tell is to watch how much it is reducing. Without
    /// it the two knobs here are guesswork.
    ///
    /// The dynamics processor publishes it as a read-only parameter, so this is
    /// the unit's own opinion rather than anything inferred.
    func gainReduction(of kind: EffectKind) -> Float {
        guard kind == .compressor || kind == .gate,
            let unit = unit(ownedBy: .stage(kind))
        else { return 0 }
        var value: AudioUnitParameterValue = 0
        guard
            AudioUnitGetParameter(
                unit, kDynamicsProcessorParam_CompressionAmount,
                kAudioUnitScope_Global, 0, &value) == noErr
        else { return 0 }
        // Reported as a negative number of decibels; returned as a positive
        // amount of reduction, which is what a meter shows.
        return max(0, -value)
    }

    /// Reads a knob back off the live unit, in the units the control uses.
    ///
    /// Nothing in the interface needs this: the model already holds what it
    /// set. What needs it is any check that a chain came back tuned the way it
    /// was left — because a chain rebuilt at its defaults looks entirely
    /// correct from the model's side, which is exactly how every knob anybody
    /// had moved used to revert silently on a restart while the interface went
    /// on showing the number they chose. The only witness is the unit.
    ///
    /// Covers the knobs that are one unit parameter. The character stage is two
    /// knobs over one unit and reads back through `characterState`; reverb's
    /// size writes two parameters and reads back through the first.
    ///
    /// - Parameters:
    ///   - parameter: The control's identifier, as `set` takes it.
    ///   - kind: Which stage it belongs to.
    /// - Returns: The value the unit is holding, or nil when the stage is not
    ///   in this chain or the knob is not one this can read.
    func value(_ parameter: String, of kind: EffectKind) -> Float? {
        if kind == .formant {
            guard parameter == "shift", let native else { return nil }
            return (native.ratio - 1) * 100
        }
        guard let unit = unit(ownedBy: .stage(kind)),
            let mapping = Self.directParameter(parameter, of: kind)
        else { return nil }
        var value: AudioUnitParameterValue = 0
        guard
            AudioUnitGetParameter(
                unit, mapping.id, kAudioUnitScope_Global, 0, &value) == noErr
        else { return nil }
        return value / mapping.scale
    }

    /// The unit parameter behind a knob, and what the knob's units are worth in
    /// the unit's own — a release control in milliseconds against a unit that
    /// wants seconds.
    private static func directParameter(
        _ parameter: String, of kind: EffectKind
    )
        -> (id: AudioUnitParameterID, scale: Float)?
    {
        switch (kind, parameter) {
        case (.tone, let name):
            guard name.hasPrefix("b"), let band = Int(name.dropFirst()),
                band < EffectKind.toneBands.count
            else { return nil }
            return (
                AudioUnitParameterID(kAUNBandEQParam_Gain) + AudioUnitParameterID(band), 1
            )
        case (.pitch, "cents"): return (AudioUnitParameterID(kNewTimePitchParam_Pitch), 1)
        case (.reverb, "mix"): return (AudioUnitParameterID(kReverb2Param_DryWetMix), 1)
        case (.reverb, "decay"):
            return (AudioUnitParameterID(kReverb2Param_DecayTimeAt0Hz), 1)
        case (.echo, "mix"): return (kDelayParam_WetDryMix, 1)
        case (.echo, "time"): return (kDelayParam_DelayTime, 0.001)
        case (.echo, "feedback"): return (kDelayParam_Feedback, 1)
        case (.voiceIsolation, "mix"):
            return (AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent), 1)
        case (.gate, "threshold"): return (kDynamicsProcessorParam_ExpansionThreshold, 1)
        case (.gate, "ratio"): return (kDynamicsProcessorParam_ExpansionRatio, 1)
        case (.gate, "release"): return (kDynamicsProcessorParam_ReleaseTime, 0.001)
        case (.equaliser, "frequency"):
            return (AudioUnitParameterID(kAUNBandEQParam_Frequency), 1)
        case (.compressor, "threshold"): return (kDynamicsProcessorParam_Threshold, 1)
        case (.compressor, "headroom"): return (kDynamicsProcessorParam_HeadRoom, 1)
        case (.limiter, "gain"): return (kLimiterParam_PreGain, 1)
        default: return nil
        }
    }

    /// How many units the chain built, for tests that care about placement.
    var unitCountForTesting: Int { units.count }

    /// Whether the native stage needs storage between hosted stages.
    ///
    /// A native tail must be false: its output is already the chain output, and
    /// allocating a work buffer there is evidence that the copy fast path was
    /// lost even when the samples still sound right.
    var hasNativeWorkBufferForTesting: Bool { nativeBuffer != nil }

    /// What a hosted plugin says its controls are.
    func parameters(ofPlugin id: String) -> [EffectParameter] {
        guard let unit = unit(ownedBy: .plugin(id)) else { return [] }
        return AudioUnitPlugins.parameters(of: unit)
    }

    func set(_ parameter: String, of kind: EffectKind, to value: Float) {
        if kind == .formant {
            // A percentage either way, which is what the control says. −20%
            // reads the envelope from higher up and moves the resonances down.
            if parameter == "shift" { native?.ratio = 1 + value / 100 }
            return
        }
        guard let unit = unit(ownedBy: .stage(kind)) else {
            return
        }
        switch (kind, parameter) {
        case (.character, "flavour"):
            let flavour =
                EffectKind.Flavour(rawValue: Int(value.rounded())) ?? .robot
            flavours[kind] = flavour
            applyFlavour(flavour, amount: amounts[kind] ?? 60, to: unit)
        case (.character, "amount"):
            amounts[kind] = value
            // Re-applied whole rather than only setting the final mix: the
            // flavour and the amount are one state, and setting half of it is
            // how a control ends up doing something different depending on
            // which order the two were touched in.
            applyFlavour(flavours[kind] ?? .robot, amount: value, to: unit)
        case (.tone, let name):
            guard let index = Int(name.dropFirst()), name.hasPrefix("b"),
                index < EffectKind.toneBands.count
            else { break }
            AudioUnitSetParameter(
                unit,
                AudioUnitParameterID(kAUNBandEQParam_Gain) + AudioUnitParameterID(index),
                kAudioUnitScope_Global, 0, value, 0)
        case (.pitch, "cents"):
            AudioUnitSetParameter(
                unit, AudioUnitParameterID(kNewTimePitchParam_Pitch),
                kAudioUnitScope_Global, 0, value, 0)
        case (.reverb, "mix"):
            AudioUnitSetParameter(
                unit, AudioUnitParameterID(kReverb2Param_DryWetMix),
                kAudioUnitScope_Global, 0, value, 0)
        case (.reverb, "decay"):
            AudioUnitSetParameter(
                unit, AudioUnitParameterID(kReverb2Param_DecayTimeAt0Hz),
                kAudioUnitScope_Global, 0, value, 0)
            // The top always decays faster, in the same proportion, so the
            // control stays one knob rather than two that have to be kept in
            // step by hand.
            AudioUnitSetParameter(
                unit, AudioUnitParameterID(kReverb2Param_DecayTimeAtNyquist),
                kAudioUnitScope_Global, 0, value * 0.5, 0)
        case (.echo, "mix"):
            AudioUnitSetParameter(
                unit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, value, 0)
        case (.echo, "time"):
            // The knob is in milliseconds because that is how anybody thinks
            // about an echo; the unit wants seconds.
            AudioUnitSetParameter(
                unit, kDelayParam_DelayTime, kAudioUnitScope_Global, 0, value / 1000, 0)
        case (.echo, "feedback"):
            AudioUnitSetParameter(
                unit, kDelayParam_Feedback, kAudioUnitScope_Global, 0, value, 0)
        case (.voiceIsolation, "mix"):
            AudioUnitSetParameter(
                unit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                kAudioUnitScope_Global, 0, value, 0)
        case (.gate, "threshold"):
            AudioUnitSetParameter(
                unit, kDynamicsProcessorParam_ExpansionThreshold,
                kAudioUnitScope_Global, 0, value, 0)
        case (.gate, "ratio"):
            AudioUnitSetParameter(
                unit, kDynamicsProcessorParam_ExpansionRatio,
                kAudioUnitScope_Global, 0, value, 0)
        case (.gate, "release"):
            AudioUnitSetParameter(
                unit, kDynamicsProcessorParam_ReleaseTime,
                kAudioUnitScope_Global, 0, value / 1000, 0)
        case (.equaliser, "frequency"):
            AudioUnitSetParameter(
                unit, AudioUnitParameterID(kAUNBandEQParam_Frequency),
                kAudioUnitScope_Global, 0, value, 0)
        case (.compressor, "threshold"):
            AudioUnitSetParameter(
                unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, value, 0)
        case (.compressor, "headroom"):
            AudioUnitSetParameter(
                unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, value, 0)
        case (.limiter, "gain"):
            AudioUnitSetParameter(
                unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, value, 0)
        default:
            break
        }
    }

    /// Renders `frames` from `inputBuffer` through every stage into
    /// `outputBuffer`. Called on the IO thread.
    @inline(__always)
    func render(frames: Int, sampleTime: Float64) -> Bool {
        // The native stage splits the run in two. Everything before it renders
        // into its own buffer, it rewrites that in place, and everything after
        // pulls from the result.
        if let native {
            let split = nativeIndex ?? 0
            if split == units.count {
                // The native stage is the tail, so `outputBuffer` is already
                // its destination. The previous path always went through
                // `nativeBuffer` and copied the result back: two block copies
                // for a formant-only chain and one after a hosted head. Here
                // the only copy left is the unavoidable input staging when
                // there is no hosted head at all.
                if split > 0 {
                    nativeTimestamp.mSampleTime = sampleTime
                    bufferList[0].mDataByteSize =
                        UInt32(frames * MemoryLayout<Float>.size)
                    var flags = AudioUnitRenderActionFlags()
                    guard
                        AudioUnitRender(
                            units[split - 1].instance, &flags, &nativeTimestamp, 0,
                            UInt32(frames), bufferList.unsafeMutablePointer) == noErr
                    else { return false }
                } else {
                    outputBuffer.update(from: inputBuffer, count: frames)
                }
                native.process(outputBuffer, count: frames)
                return true
            }

            guard let nativeBuffer, let nativeList else { return false }
            if split > 0 {
                nativeTimestamp.mSampleTime = sampleTime
                nativeList[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
                var flags = AudioUnitRenderActionFlags()
                guard
                    AudioUnitRender(
                        units[split - 1].instance, &flags, &nativeTimestamp, 0,
                        UInt32(frames), nativeList.unsafeMutablePointer) == noErr
                else { return false }
            } else {
                nativeBuffer.update(from: inputBuffer, count: frames)
            }

            native.process(nativeBuffer, count: frames)
        }

        guard let tail = units.last?.instance else { return false }
        timestamp.mSampleTime = sampleTime
        bufferList[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        var flags = AudioUnitRenderActionFlags()
        return AudioUnitRender(
            tail, &flags, &timestamp, 0, UInt32(frames),
            bufferList.unsafeMutablePointer) == noErr
    }
}
