import Foundation

/// How far a song has been transposed, in semitones.
///
/// The button every KTV machine has beside play and pause, and the one this
/// application could not offer while every song belonged to another process:
/// nothing in a scripting dictionary transposes anything. A song we are playing
/// ourselves goes through our own node chain, so it is a parameter.
///
/// Kept per song for the same reason the lyric offset is — see
/// [[LyricOffsets]], whose shape this deliberately copies. A key is a fact
/// about a particular singer and a particular song: somebody who takes 慢冷
/// down two takes it down two every time, and being asked again each evening is
/// the feature not working.
enum SongKeys {
    static let key = "YunAudioSongKeys"

    /// Six either way.
    ///
    /// A perfect fourth up or a diminished fifth down is already past what a
    /// backing track survives — the time-pitch unit is stretching a mixed
    /// recording, not resynthesising it, and the artefacts arrive long before
    /// the twelfth semitone. Six also makes the two buttons reachable: one press
    /// per semitone, and the far end is six presses rather than twelve.
    static let limit = 6

    /// Cents per semitone. The unit is set in cents because a decent transpose
    /// is rarely a whole number of semitones — see `EffectKind.pitch` — but the
    /// control offered here is, because a KTV key is.
    static let centsPerSemitone: Float = 100

    static func semitones(
        for identity: String, in defaults: UserDefaults = .standard
    )
        -> Int
    {
        guard !identity.isEmpty,
            let stored = defaults.dictionary(forKey: key)?[identity] as? Int
        else { return 0 }
        return clamped(stored)
    }

    /// - Returns: The key now in force, so a caller can show it.
    @discardableResult
    static func shift(
        _ identity: String, by delta: Int, in defaults: UserDefaults = .standard
    ) -> Int {
        guard !identity.isEmpty else { return 0 }
        let updated = clamped(semitones(for: identity, in: defaults) + delta)
        var all = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        // The original key is the absence of an entry rather than an entry
        // saying zero, so the store holds only songs somebody actually moved.
        if updated == 0 {
            all.removeValue(forKey: identity)
        } else {
            all[identity] = updated
        }
        defaults.set(all, forKey: key)
        return updated
    }

    static func clear(_ identity: String, in defaults: UserDefaults = .standard) {
        guard var all = defaults.dictionary(forKey: key) as? [String: Int],
            all.removeValue(forKey: identity) != nil
        else { return }
        defaults.set(all, forKey: key)
    }

    static func clamped(_ semitones: Int) -> Int {
        max(-limit, min(limit, semitones))
    }

    static func cents(forSemitones semitones: Int) -> Float {
        Float(clamped(semitones)) * centsPerSemitone
    }

    /// What to call a key on screen: `+2`, `−1`, or the original.
    ///
    /// A minus sign rather than a hyphen, because the two are a different width
    /// and the control has a number either side of it that must not jump.
    static func title(_ semitones: Int, original: String) -> String {
        switch clamped(semitones) {
        case 0: original
        case let value where value > 0: "+\(value)"
        case let value: "−\(abs(value))"
        }
    }
}
