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
        case .gate: 2
        // After the gate: shifting first would move the noise floor along with
        // the voice and give the gate a moving target.
        case .pitch: 3
        // Directly after the pitch shift and before anything else: the two are
        // one effect as far as a listener is concerned, and putting a
        // compressor between them would make the character depend on how loud
        // somebody happened to be.
        case .formant: 4
        // After both, so the character is applied to the voice as it is going
        // to be heard rather than as it arrived.
        case .character: 5
        case .compressor: 6
        // The room goes on after the level has been evened out, or the reverb
        // tail gets compressed along with the voice and breathes.
        case .echo: 7
        case .reverb: 8
        // Always last. Anything after a limiter can put the signal back over
        // full scale, which is the one thing it was there to prevent.
        case .limiter: 9
        }
    }
}

/// A series of Audio Units rendered on the IO thread.
///
/// Each stage pulls from the previous one through a render callback, which is
/// how Audio Units are meant to be chained — the alternative, rendering each
/// into a scratch buffer by hand, means one more copy per stage and no benefit.
final class EffectChain {
    /// Buffer the first stage pulls from. The IOProc fills it before rendering.
    let inputBuffer: UnsafeMutablePointer<Float>
    let outputBuffer: UnsafeMutablePointer<Float>
    let maximumFrames: Int

    private(set) var stages: [EffectKind] = []
    /// The stages that became units, in the same order as `units`.
    ///
    /// Not `stages`: the native stage produces no unit, so pairing `stages`
    /// with `units` by index silently hands every stage after it the wrong
    /// unit — the compressor would be configured as a limiter and nothing
    /// would say so.
    private var hostedStages: [EffectKind] = []
    private var units: [AudioComponentInstance] = []
    /// The one stage written here rather than hosted, and where it sits in the
    /// run of units.
    private var native: FormantShifter?
    private var nativeIndex: Int?
    /// What the first half of the chain produced, which the native stage
    /// rewrites in place and the second half then pulls from.
    private var nativeBuffer: UnsafeMutablePointer<Float>?
    private var nativeList: UnsafeMutableAudioBufferListPointer?
    private var nativeTimestamp = AudioTimeStamp()
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private var timestamp = AudioTimeStamp()

    /// Total latency the chain adds, in frames.
    private(set) var latencyFrames = 0

    init?(kinds: [EffectKind], sampleRate: Double, maximumFrames: Int) {
        guard !kinds.isEmpty else { return nil }
        self.maximumFrames = maximumFrames
        stages = kinds.sorted { $0.chainOrder < $1.chainOrder }

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
        for kind in stages {
            if kind.isNative {
                nativeIndex = units.count
                native = FormantShifter()
                continue
            }
            hostedStages.append(kind)
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
            units.append(unit)
        }

        // A chain of nothing but the native stage is legitimate: somebody who
        // wants only a formant shift should get one.
        guard !units.isEmpty || native != nil else {
            inputBuffer.deallocate()
            outputBuffer.deallocate()
            free(bufferList.unsafeMutablePointer)
            return nil
        }

        if native != nil {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)
            buffer.initialize(repeating: 0, count: maximumFrames)
            nativeBuffer = buffer
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            list[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maximumFrames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buffer))
            nativeList = list
            nativeTimestamp.mFlags = .sampleTimeValid
        }

        // The head pulls from our staging buffer; every later stage pulls from
        // the one before it.
        var headCallback = AURenderCallbackStruct(
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
            AudioUnitSetProperty(
                units[0], kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &headCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
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
                    units[index], kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input, 0,
                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
                continue
            }
            var connection = AudioUnitConnection(
                sourceAudioUnit: units[index - 1],
                sourceOutputNumber: 0,
                destInputNumber: 0)
            AudioUnitSetProperty(
                units[index], kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0,
                &connection, UInt32(MemoryLayout<AudioUnitConnection>.size))
        }

        for unit in units where AudioUnitInitialize(unit) != noErr {
            // A stage that will not initialise is worse than no chain: the
            // signal would silently skip it while the UI claimed it was on.
            teardown()
            inputBuffer.deallocate()
            outputBuffer.deallocate()
            free(bufferList.unsafeMutablePointer)
            return nil
        }

        latencyFrames = (native?.latencyFrames ?? 0)
        latencyFrames += units.reduce(into: 0) { total, unit in
            var latency: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
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
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        units.removeAll()
    }

    /// Starting points chosen for a voice signal rather than the units' own
    /// defaults, which are tuned for music.
    private func applyDefaults(sampleRate: Double) {
        for (index, kind) in hostedStages.enumerated() where index < units.count {
            let unit = units[index]
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
                // in `hostedStages`. Stated rather than left to `default`, so
                // that adding another native stage fails to compile here
                // instead of silently configuring the wrong unit.
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
    func set(_ parameter: String, of kind: EffectKind, to value: Float) {
        if kind == .formant {
            // A percentage either way, which is what the control says. −20%
            // reads the envelope from higher up and moves the resonances down.
            if parameter == "shift" { native?.ratio = 1 + value / 100 }
            return
        }
        guard let index = hostedStages.firstIndex(of: kind), index < units.count else {
            return
        }
        let unit = units[index]
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
        if let native, let nativeBuffer, let nativeList {
            let split = nativeIndex ?? 0
            if split > 0 {
                nativeTimestamp.mSampleTime = sampleTime
                nativeList[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
                var flags = AudioUnitRenderActionFlags()
                guard
                    AudioUnitRender(
                        units[split - 1], &flags, &nativeTimestamp, 0, UInt32(frames),
                        nativeList.unsafeMutablePointer) == noErr
                else { return false }
            } else {
                nativeBuffer.update(from: inputBuffer, count: frames)
            }

            native.process(nativeBuffer, count: frames)

            guard split < units.count else {
                // Nothing after it, so what it produced is the output.
                outputBuffer.update(from: nativeBuffer, count: frames)
                return true
            }
        }

        guard let tail = units.last else { return false }
        timestamp.mSampleTime = sampleTime
        bufferList[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        var flags = AudioUnitRenderActionFlags()
        return AudioUnitRender(
            tail, &flags, &timestamp, 0, UInt32(frames),
            bufferList.unsafeMutablePointer) == noErr
    }
}
