import Foundation

/// Which index a song's words should come from, when the chosen one is wrong.
///
/// Ranking picks the best answer by title, artist and running time, and it is
/// right most of the time. When it is not, nothing else in the application can
/// help: the words on screen belong to a cover, or a live take, or a different
/// edit, and every reopen of that song picks the same one again. Remembering a
/// person's answer is the only way that stops being a fault they meet daily.
///
/// Per song, because the fault is per song — one index being wrong about
/// 「慢冷」 says nothing about the next track.
enum LyricSourceChoice {
    static let key = "YunAudioLyricSources"

    static func preferred(for identity: String, in defaults: UserDefaults = .standard)
        -> OnlineLyrics.Source?
    {
        guard !identity.isEmpty,
            let raw = defaults.dictionary(forKey: key)?[identity] as? String
        else { return nil }
        return OnlineLyrics.Source(rawValue: raw)
    }

    static func remember(
        _ source: OnlineLyrics.Source, for identity: String,
        in defaults: UserDefaults = .standard
    ) {
        guard !identity.isEmpty else { return }
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[identity] = source.rawValue
        defaults.set(all, forKey: key)
    }

    static func forget(_ identity: String, in defaults: UserDefaults = .standard) {
        guard var all = defaults.dictionary(forKey: key) as? [String: String],
            all.removeValue(forKey: identity) != nil
        else { return }
        defaults.set(all, forKey: key)
    }

    /// The one after `current` among the answers that came back, wrapping.
    ///
    /// Cycling rather than presenting a list: at the moment somebody notices
    /// the words are wrong they do not know which index is right either, and
    /// pressing once until it looks correct is the shape of that question.
    /// Sorted, so the order is the same every time and pressing twice returns
    /// to where it started rather than shuffling.
    static func next(
        after current: OnlineLyrics.Source?, among available: [OnlineLyrics.Source]
    ) -> OnlineLyrics.Source? {
        let ordered = Array(Set(available)).sorted { $0.rawValue < $1.rawValue }
        guard !ordered.isEmpty else { return nil }
        guard let current, let index = ordered.firstIndex(of: current) else {
            return ordered[0]
        }
        return ordered[(index + 1) % ordered.count]
    }
}
