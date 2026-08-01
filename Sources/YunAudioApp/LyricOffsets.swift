import Foundation

/// How far a song's words have been nudged against its music, in seconds.
///
/// Negative holds them back. A published `.lrc` is timed against whatever
/// master the person who made it had, and that is routinely not the recording
/// being played: 「慢冷」 arrives with its first line at the very start and no
/// lead-in at all, so at four seconds the stage is already lighting a line
/// nobody has sung. Nothing in the file says so, and no amount of better
/// matching finds a better file — the words are right and the clock is not.
///
/// Kept per song, because the fault is per file, and in `UserDefaults` rather
/// than in the preferences snapshot: that snapshot is rebuilt wholesale on
/// every control change, and a map that grows by one entry per song ever
/// nudged does not belong in something rewritten that often.
enum LyricOffsets {
    static let key = "YunAudioLyricOffsets"

    /// Beyond this a nudge is not an alignment, and a stored value that large
    /// is more likely a stuck key than an intention.
    static let limit: Double = 30

    static func offset(
        for identity: String, in defaults: UserDefaults = .standard
    )
        -> Double
    {
        guard !identity.isEmpty,
            let stored = defaults.dictionary(forKey: key)?[identity] as? Double
        else { return 0 }
        return clamped(stored)
    }

    /// - Returns: The offset now in force, so a caller can show it.
    @discardableResult
    static func nudge(
        _ identity: String, by delta: Double, in defaults: UserDefaults = .standard
    ) -> Double {
        guard !identity.isEmpty else { return 0 }
        let updated = clamped(offset(for: identity, in: defaults) + delta)
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        // Zero is the absence of an entry, not an entry saying zero. A file
        // that accumulates a line per song ever played is one nobody can read
        // and nothing can prune.
        if abs(updated) < 0.01 {
            all.removeValue(forKey: identity)
        } else {
            all[identity] = updated
        }
        defaults.set(all, forKey: key)
        return updated
    }

    static func clear(_ identity: String, in defaults: UserDefaults = .standard) {
        guard var all = defaults.dictionary(forKey: key) as? [String: Double],
            all.removeValue(forKey: identity) != nil
        else { return }
        defaults.set(all, forKey: key)
    }

    static func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return max(-limit, min(limit, seconds))
    }
}
