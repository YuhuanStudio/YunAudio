import Foundation

public struct AccompanimentCandidate: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var duration: TimeInterval?

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

public struct RankedAccompanimentCandidate: Equatable, Sendable {
    public var candidate: AccompanimentCandidate
    public var score: Int

    public init(candidate: AccompanimentCandidate, score: Int) {
        self.candidate = candidate
        self.score = score
    }
}

public enum AccompanimentSearch {
    private static let positiveTerms: [(String, Int)] = [
        ("伴奏", 80),
        ("纯伴奏", 100),
        ("純伴奏", 100),
        ("off vocal", 90),
        ("karaoke", 75),
        ("instrumental", 75),
    ]
    private static let negativeTerms: [(String, Int)] = [
        ("original", -45),
        ("official music video", -60),
        ("official video", -45),
        ("mv", -55),
        ("lyrics", -35),
        ("lyric video", -45),
        ("live", -45),
        ("现场", -45),
        ("現場", -45),
    ]

    public static func query(title: String, artist: String?) -> String {
        [MusicTitle.canonical(title), artist?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ") + " 伴奏 off vocal karaoke instrumental"
    }

    public static func youtubeSearchURL(title: String, artist: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/results"
        components.queryItems = [
            URLQueryItem(name: "search_query", value: query(title: title, artist: artist))
        ]
        return components.url
    }

    public static func ranked(
        _ candidates: [AccompanimentCandidate],
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) -> [RankedAccompanimentCandidate] {
        let wantedTitle = MusicTitle.matchingKey(title)
        let wantedArtist = artist.map(MusicTitle.matchingKey) ?? ""

        return candidates.enumerated().map { index, candidate in
            let candidateTitle = MusicTitle.matchingKey(candidate.title)
            let candidateArtist = candidate.artist.map(MusicTitle.matchingKey) ?? ""
            var score = 0

            if !wantedTitle.isEmpty, candidateTitle.contains(wantedTitle) {
                score += 100
            }
            if !wantedArtist.isEmpty,
                candidateArtist.contains(wantedArtist)
                    || candidateTitle.contains(wantedArtist)
            {
                score += 40
            }
            for (term, points) in positiveTerms
            where contains(term: term, in: candidate.title) {
                score += points
            }
            for (term, points) in negativeTerms
            where contains(term: term, in: candidate.title) {
                score += points
            }
            if let duration, duration.isFinite, duration > 0,
                let candidateDuration = candidate.duration,
                candidateDuration.isFinite, candidateDuration > 0
            {
                let difference = abs(duration - candidateDuration)
                score += max(-40, 40 - Int(difference.rounded()))
            }
            return (index, RankedAccompanimentCandidate(candidate: candidate, score: score))
        }
        .sorted {
            if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
            return $0.0 < $1.0
        }
        .map(\.1)
    }

    private static func contains(term: String, in value: String) -> Bool {
        if term.unicodeScalars.contains(where: { !$0.isASCII }) {
            return MusicTitle.rawNormalised(value).contains(
                MusicTitle.rawNormalised(term))
        }
        let words = value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return " \(words) ".contains(" \(term) ")
    }
}
