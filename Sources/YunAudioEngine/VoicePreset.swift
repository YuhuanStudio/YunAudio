import Foundation

/// A whole voice, rather than two knobs somebody has to find the combination of.
///
/// Pitch and formants are separate stages because they are separate physical
/// facts, but nobody wants to be told that. What they want is to sound like a
/// woman, and the answer is not one control — it is a specific pair of them.
/// Moving pitch alone gives a chipmunk; moving formants alone gives somebody
/// speaking through a tube; moving both by the right amounts gives a different
/// person.
///
/// The numbers are not invented. An adult male speaking voice sits around 110
/// to 130 Hz and an adult female around 200 to 220, which is roughly a fifth —
/// but a full fifth of pitch shift with nothing else is unmistakably processed,
/// because the resonances did not move with it. Female formants run about 15 to
/// 20 per cent higher than male ones, from a vocal tract about that much
/// shorter. Shift both and the ear stops hearing an effect.
///
/// What this is not: neural voice conversion. Something like fish-speech or RVC
/// learns a target speaker and resynthesises, which is a different and better
/// thing — and needs a model, a GPU pipeline and well over a hundred
/// milliseconds. None of that fits inside a 2.7 ms IO deadline. Every real-time
/// voice changer that ships today does what this does, and says so.
public enum VoicePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Nothing at all: the stages sit at unity.
    case none
    /// Up a fourth, with the vocal tract shortened to match.
    case masculineToFeminine
    /// Down, with the tract lengthened.
    case feminineToMasculine
    /// Much higher and much shorter. Convincing as a child, not as an adult.
    case child
    /// Lower and longer, without the clipping that makes a monster.
    case deep
    /// A small shift either way, for somebody who wants to be harder to
    /// recognise rather than to be somebody else.
    case disguise

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "None"
        case .masculineToFeminine: "Higher voice"
        case .feminineToMasculine: "Lower voice"
        case .child: "Child"
        case .deep: "Deep"
        case .disguise: "Disguise"
        }
    }

    public var detail: String {
        switch self {
        case .none: "The voice as it arrived."
        case .masculineToFeminine:
            "Up a fourth, with the vocal tract shortened to match. Both together is "
                + "what stops it sounding like a chipmunk."
        case .feminineToMasculine: "Down, with the tract lengthened by the same reasoning."
        case .child: "Much higher and much shorter. Convincing as a child, not as an adult."
        case .deep: "Lower and longer. Larger, without the grit of the monster character."
        case .disguise:
            "A small move in both. Harder to recognise rather than somebody else."
        }
    }

    /// Pitch shift in cents. 100 is a semitone.
    public var cents: Float {
        switch self {
        case .none: 0
        // A fifth is the honest distance between the two ranges and sounds
        // overdone; a fourth lands inside a female range without the artefacts
        // a large shift brings with it.
        case .masculineToFeminine: 500
        case .feminineToMasculine: -450
        case .child: 800
        case .deep: -400
        case .disguise: 200
        }
    }

    /// Formant shift as a percentage, the control the stage takes.
    public var formantPercent: Float {
        switch self {
        case .none: 0
        // A female vocal tract is about 15 per cent shorter, so the resonances
        // sit about that much higher.
        case .masculineToFeminine: 17
        case .feminineToMasculine: -14
        case .child: 30
        case .deep: -18
        case .disguise: 8
        }
    }

    /// The stages a preset needs switched on. Nothing is enabled that the
    /// preset does not move, because an idle stage still costs latency.
    public var stages: Set<EffectKind> {
        guard self != .none else { return [] }
        var wanted: Set<EffectKind> = []
        if cents != 0 { wanted.insert(.pitch) }
        if formantPercent != 0 { wanted.insert(.formant) }
        return wanted
    }

    /// What it costs, in frames, at a given rate.
    ///
    /// Worth stating rather than discovering: a voice change is not free and
    /// the two stages together are the most latency this application can add
    /// short of voice isolation.
    public func latencyFrames(sampleRate: Double) -> Int {
        var frames = 0
        if formantPercent != 0 { frames += FormantShifter.windowSize }
        // The pitch unit's own latency is read from the unit when the chain is
        // built; this is the published figure for planning.
        if cents != 0 { frames += Int(sampleRate * 0.03) }
        return frames
    }
}
