import Foundation

/// Drives a gain towards a loudness target.
///
/// The usual automatic gain control watches an envelope and turns everything it
/// hears towards a level. That is why AGC has the reputation it has: it winds
/// the gain up through every pause until the room noise is as loud as the voice
/// was, and then ducks when you speak again. What is wrong with it is not the
/// control loop, it is the measurement — an envelope cannot tell a voice from a
/// fan.
///
/// This one is different in two ways that matter. It measures loudness to the
/// broadcast standard rather than amplitude, so its idea of "as loud as
/// everyone else" is the same one the platform on the other end will use. And
/// it only moves while a classifier says it is hearing speech, so pauses,
/// keyboards and air conditioning are not evidence about how loud anybody is.
///
/// Deliberately a value type with no dependencies: a control loop that is not
/// tested oscillates, and one that can only be exercised through a live
/// microphone is not tested.
public struct AutoLevel: Sendable {

    /// How far from the target the loudness has to be before anything moves.
    ///
    /// A unit either way is inaudible. Without a dead zone the loop chases the
    /// noise in its own measurement forever, which is audible as slow breathing
    /// even though the number looks stable.
    public static let deadZone: Double = 1.0

    /// The fastest the gain is allowed to move, in decibels per second.
    ///
    /// Broadcast levellers sit between one and three. Faster is heard as
    /// pumping; slower takes so long to settle that the first sentence of every
    /// call is at the wrong level.
    public static let slewPerSecond: Double = 1.5

    /// How far the loop may move the gain in total. Past this something is
    /// wrong with the setup — the microphone's own gain is miles off, or it is
    /// pointed at the wrong thing — and quietly adding 40 dB of make-up would
    /// hide that rather than fix it.
    public static let limit: Double = 15

    /// Below this there is no signal worth levelling, whatever the classifier
    /// thinks. A speech verdict on something 60 dB down is the classifier being
    /// polite about silence.
    public static let floor: Double = -50

    /// Correction applied so far, in decibels.
    public private(set) var offset: Double = 0
    /// True while the loop is holding still because it has nothing to act on.
    public private(set) var isWaiting = true
    /// True when it wanted more gain and the peak would not allow it. Worth
    /// surfacing: it means the source is quiet *and* peaky, which is a
    /// microphone placement problem rather than a gain one.
    public private(set) var isHeldByHeadroom = false

    public init() {}

    /// Advances the loop.
    ///
    /// - Parameters:
    ///   - loudness: Short-term loudness in LUFS. Short-term rather than
    ///     momentary because momentary swings by ten units inside a sentence,
    ///     and rather than integrated because integrated stops responding once
    ///     enough material has accumulated — which is exactly when somebody
    ///     leans away from the microphone.
    ///   - target: Where it should end up.
    ///   - hearsSpeech: The classifier's verdict.
    ///   - elapsed: Seconds since the last call. The slew limit is per second,
    ///     so this cannot be assumed.
    ///   - ceiling: The largest offset the signal has headroom for right now,
    ///     from the measured peak. Loudness and peak are different questions,
    ///     and a leveller that only answered the first would happily add 12 dB
    ///     to something already peaking at −2 dBFS and hand the far end
    ///     distortion in exchange for hitting a number. Quiet-but-clean always
    ///     beats correct-but-clipped.
    /// - Returns: The new total offset in decibels.
    @discardableResult
    public mutating func update(
        loudness: Double, target: Double, hearsSpeech: Bool, elapsed: Double,
        ceiling: Double = .infinity
    ) -> Double {
        guard hearsSpeech, loudness.isFinite, loudness > Self.floor, elapsed > 0 else {
            isWaiting = true
            return offset
        }
        isWaiting = false

        let error = target - loudness
        guard abs(error) > Self.deadZone else { return offset }

        // Proportional, then slew limited. A proportional term alone would take
        // the whole error in one step and be heard; the slew is what makes the
        // correction arrive under the threshold of noticing.
        let step = max(-Self.slewPerSecond * elapsed, min(Self.slewPerSecond * elapsed, error))
        var next = max(-Self.limit, min(Self.limit, offset + step))
        // The ceiling only ever holds it back, never pushes it up: a ceiling
        // below where the loop already is means the peak has grown since, and
        // the answer to that is to stop adding, not to lunge downwards.
        if next > offset { next = min(next, max(offset, ceiling)) }
        isHeldByHeadroom = next < offset + step - 0.0001
        offset = next
        return offset
    }

    /// True when the loop has run out of room. The interface should say so
    /// rather than appearing to work.
    public var isAtLimit: Bool { abs(abs(offset) - Self.limit) < 0.001 }

    public mutating func reset() {
        offset = 0
        isWaiting = true
        isHeldByHeadroom = false
    }
}
