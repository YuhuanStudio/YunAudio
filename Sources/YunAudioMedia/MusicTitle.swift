import Foundation

public enum MusicTitleOrder: Sendable {
    case titleThenArtist
    case artistThenTitle
}

public struct ParsedMusicTitle: Equatable, Sendable {
    public var title: String
    public var artist: String?

    public init(title: String, artist: String?) {
        self.title = title
        self.artist = artist
    }
}

public enum MusicTitle {
    private static let siteSuffixes = [
        "youtube", "qq音乐", "qq音樂", "网易云音乐", "網易雲音樂",
    ]
    private static let suffixMarkers = [
        "official music video", "official video", "lyrics video", "lyric video",
        "完整版", "纯享版", "純享版", "现场版", "現場版", "live",
    ]
    private static let bracketMarkers =
        suffixMarkers + [
            "天赐的声音", "天賜的聲音",
        ]

    public static func parse(
        _ rawValue: String,
        order: MusicTitleOrder
    ) -> ParsedMusicTitle {
        let withoutSite = canonical(removingSiteSuffix(from: rawValue))
        for separator in [" — ", " – ", " - ", " | "] {
            let parts = withoutSite.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let first = canonical(parts[0])
            let second = canonical(parts[1])
            guard !first.isEmpty, !second.isEmpty else { break }
            switch order {
            case .titleThenArtist:
                return ParsedMusicTitle(title: first, artist: second)
            case .artistThenTitle:
                return ParsedMusicTitle(title: second, artist: first)
            }
        }
        return ParsedMusicTitle(title: canonical(withoutSite), artist: nil)
    }

    public static func canonical(_ rawValue: String) -> String {
        var value = rawValue.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value = removingEditionBrackets(from: value)

        var removed = true
        while removed {
            removed = false
            for marker in suffixMarkers {
                guard
                    let range = value.range(
                        of: marker,
                        options: [.caseInsensitive, .diacriticInsensitive, .backwards]),
                    value[range.upperBound...].allSatisfy({
                        $0.isWhitespace || "-–—|·".contains($0)
                    }),
                    range.lowerBound > value.startIndex,
                    isWordBoundary(in: value, before: range.lowerBound, marker: marker)
                else { continue }
                value.removeSubrange(range.lowerBound..<value.endIndex)
                value = value.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines.union(
                        CharacterSet(charactersIn: "-–—|·")))
                removed = true
                break
            }
        }
        return value
    }

    public static func normalised(_ rawValue: String) -> String {
        canonical(rawValue)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    public static func matchingKey(_ rawValue: String) -> String {
        let canonical = canonical(rawValue)
        let latin = canonical.applyingTransform(.toLatin, reverse: false) ?? canonical
        return rawKey(latin)
    }

    private static func removingSiteSuffix(from rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" - ", " | ", " — ", " – "] {
            guard let range = value.range(of: separator, options: .backwards) else {
                continue
            }
            let suffix = String(value[range.upperBound...])
            guard siteSuffixes.contains(where: { rawKey($0) == rawKey(suffix) })
            else { continue }
            value.removeSubrange(range.lowerBound..<value.endIndex)
            break
        }
        return value
    }

    private static func removingEditionBrackets(from rawValue: String) -> String {
        var value = rawValue
        for pair in [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】")] {
            var searchStart = value.startIndex
            while let opening = value.range(
                of: pair.0, range: searchStart..<value.endIndex),
                let closing = value.range(
                    of: pair.1, range: opening.upperBound..<value.endIndex)
            {
                let body = String(value[opening.upperBound..<closing.lowerBound])
                if bracketMarkers.contains(where: { containsEdition($0, in: body) }) {
                    value.removeSubrange(opening.lowerBound..<closing.upperBound)
                    searchStart = opening.lowerBound
                } else {
                    searchStart = closing.upperBound
                }
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordBoundary(
        in value: String,
        before index: String.Index,
        marker: String
    ) -> Bool {
        guard marker.unicodeScalars.first.map(CharacterSet.letters.contains) == true,
            index > value.startIndex
        else { return true }
        let previous = value[value.index(before: index)]
        return !previous.isLetter && !previous.isNumber
    }

    private static func rawKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func rawNormalised(_ value: String) -> String {
        rawKey(value)
    }

    private static func containsEdition(_ marker: String, in value: String) -> Bool {
        if marker.unicodeScalars.allSatisfy(\.isASCII) {
            let body = englishWords(value)
            let edition = englishWords(marker)
            return " \(body) ".contains(" \(edition) ")
        }
        return rawKey(value).contains(rawKey(marker))
    }

    private static func englishWords(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
