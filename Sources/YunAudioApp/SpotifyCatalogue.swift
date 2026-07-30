import Foundation

/// Everyone on the track, which Spotify's scripting dictionary will not say.
///
/// `artist of current track` returns one name however many performed. Measured
/// against 「离开我的依赖 - Live」 while it was playing: the Apple Event answered
/// 「王赫野」 and the track is 「王赫野 / 黃霄雲」. That truncation cost twice over
/// — the second name was missing from the display, and it was missing from the
/// list a duet lyric is matched against, so 「黃霄雲」 was drawn on the stage as
/// a line to sing rather than recognised as the marker saying who sings next.
///
/// The public embed document carries the full list and needs no credentials, no
/// registered application and no token: it is the same document Spotify serves
/// to anyone embedding a track in a web page. One request per song, cached by
/// the track's own identifier, and a failure simply leaves the scripting answer
/// in place.
enum SpotifyCatalogue {

    /// Cached by track identifier for the life of the process.
    ///
    /// A song is adopted once, so this exists for the case of returning to one:
    /// a repeat, or a playlist that comes round again. Bounded, because a long
    /// session should not accumulate a name list per track played.
    private actor Store {
        static let shared = Store()
        private var byTrack: [String: [String]] = [:]
        private var order: [String] = []
        private let limit = 256

        func cached(_ id: String) -> [String]? { byTrack[id] }

        func remember(_ names: [String], for id: String) {
            if byTrack[id] == nil { order.append(id) }
            byTrack[id] = names
            while order.count > limit {
                byTrack.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// Every performer on a track, or nil when the document did not say.
    ///
    /// - Parameter identity: `id of current track`, which Spotify gives as
    ///   `spotify:track:<id>`. Anything else is not a Spotify track and is
    ///   declined rather than guessed at.
    static func performers(forIdentity identity: String) async -> [String]? {
        guard let id = trackIdentifier(identity) else { return nil }
        if let cached = await Store.shared.cached(id) { return cached }

        var request = URLRequest(
            url: URL(string: "https://open.spotify.com/embed/track/\(id)")!)
        // Spotify serves a different document to a client it does not recognise
        // as a browser, and that one has no track data in it at all.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let document = String(data: data, encoding: .utf8),
            let names = names(inEmbedDocument: document), !names.isEmpty
        else { return nil }
        await Store.shared.remember(names, for: id)
        return names
    }

    /// `spotify:track:<id>` → `<id>`.
    static func trackIdentifier(_ identity: String) -> String? {
        let prefix = "spotify:track:"
        guard identity.hasPrefix(prefix) else { return nil }
        let id = String(identity.dropFirst(prefix.count))
        // Base62, and nothing else — this goes into a URL path.
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return id
    }

    /// Reads the performer names out of the embed document.
    ///
    /// The page carries its state as one JSON blob in a `__NEXT_DATA__` script
    /// element. Rather than depend on where in that structure the track sits —
    /// which is Spotify's to change without notice — this looks for the first
    /// object with an `artists` array of named things. A layout change then
    /// costs the second name again, which the caller already tolerates, rather
    /// than costing a crash.
    static func names(inEmbedDocument document: String) -> [String]? {
        let opening = "<script id=\"__NEXT_DATA__\" type=\"application/json\">"
        guard let start = document.range(of: opening),
            let end = document.range(
                of: "</script>", range: start.upperBound..<document.endIndex)
        else { return nil }
        let json = String(document[start.upperBound..<end.lowerBound])
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return firstArtistList(in: root)
    }

    private static func firstArtistList(in node: Any) -> [String]? {
        if let object = node as? [String: Any] {
            if let artists = object["artists"] as? [[String: Any]] {
                let names = artists.compactMap { $0["name"] as? String }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !names.isEmpty { return names }
            }
            for value in object.values {
                if let found = firstArtistList(in: value) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = firstArtistList(in: value) { return found }
            }
        }
        return nil
    }
}
