import Foundation

/// How a line is pronounced, for somebody who can follow the tune but not the
/// characters.
///
/// The common case for a Chinese lyric is not that the singer cannot read it —
/// it is that a character they know arrives faster than they can place it.
/// Pinyin under the line closes that gap, and for anybody reading a script they
/// do not know at all it is the difference between singing and miming.
///
/// Foundation's Han-to-Latin transform is the whole implementation, and its
/// limits are worth stating rather than hiding: it romanises 妳 as "nai" where
/// the modern reading is "nǐ", and it cannot know which reading a 多音字 takes
/// in context — 「重」 is "zhong" or "chong" depending on the word. Both are
/// wrong occasionally and neither is wrong silently, because the characters are
/// still there above.
enum LyricRomanisation {

    /// Cached by line, because the transform is not cheap and the stage draws
    /// the same six or seven lines for the length of a verse.
    private nonisolated(unsafe) static var cache: [String: String] = [:]
    private nonisolated(unsafe) static var order: [String] = []
    private static let limit = 512
    private static let lock = NSLock()

    /// Nil when the line needs none — Latin text romanises to itself, and a row
    /// repeating the line underneath it is worse than no row.
    static func of(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, needsRomanising(trimmed) else { return nil }

        return lock.withLock {
            if let hit = cache[trimmed] { return hit.isEmpty ? nil : hit }
            let latin =
                trimmed.applyingTransform(.toLatin, reverse: false)
                .map { $0.applyingTransform(.stripDiacritics, reverse: false) ?? $0 }?
                .trimmingCharacters(in: .whitespaces) ?? ""
            // A transform that gives back the same string has told us nothing.
            let value = latin.caseInsensitiveCompare(trimmed) == .orderedSame ? "" : latin
            cache[trimmed] = value
            order.append(trimmed)
            while order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
            return value.isEmpty ? nil : value
        }
    }

    /// Whether a line contains anything a Latin reader cannot pronounce.
    ///
    /// Scanned rather than assumed from the track's language: a Chinese song
    /// with an English chorus should romanise the verses and leave the chorus
    /// alone, and one line is the unit that decides.
    static func needsRomanising(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // CJK ideographs, kana, and Hangul — the scripts this helps with.
            (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
        }
    }
}
