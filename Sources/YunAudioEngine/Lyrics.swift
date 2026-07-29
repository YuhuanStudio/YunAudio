import Foundation

/// Time-synchronised lyrics, read from an `.lrc` file.
///
/// `.lrc` is the common representation regardless of where the words came
/// from: a local file, Music's own plain words, or one of the independently
/// queried public indexes. Keeping parsing in the engine and fetching in the
/// application makes the timeline a pure, numerically testable value and keeps
/// a network response out of the audio path.
public struct Lyrics: Sendable, Hashable {

    public struct Line: Sendable, Hashable {
        /// Seconds from the start of the track.
        public let time: Double
        public let text: String

        public init(time: Double, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// Metadata from the `[ti:]`, `[ar:]` and `[al:]` tags, when present.
    public var title: String?
    public var artist: String?
    public var album: String?
    /// A global shift, from the `[offset:]` tag, in seconds. Positive means the
    /// words are late and should be pulled earlier.
    public var offset: Double
    /// In time order, always.
    public var lines: [Line]

    public init(
        title: String? = nil, artist: String? = nil, album: String? = nil,
        offset: Double = 0, lines: [Line]
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.offset = offset
        self.lines = lines.sorted { $0.time < $1.time }
    }

    // MARK: Reading

    /// Parses an `.lrc`.
    ///
    /// The format is loose in practice and the looseness is the work:
    ///
    ///     [ti:Song]
    ///     [offset:-500]
    ///     [00:12.50]The first line
    ///     [00:17.20][01:05.44]A line that repeats
    ///
    /// One line can carry several stamps — that is how a chorus is written
    /// without repeating the words — so each stamp becomes its own entry.
    /// Fractions are two digits in most files and three in some, and the
    /// difference is a factor of ten, so it is read as written rather than
    /// assumed.
    ///
    /// - Returns: Nil when nothing in the text carried a timestamp, which is
    ///   the honest answer for a plain text file of words with no timing.
    public static func parse(_ text: String) -> Lyrics? {
        var title: String?
        var artist: String?
        var album: String?
        var offset: Double = 0
        var lines: [Line] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            var stamps: [Double] = []
            var index = line.startIndex

            // Every bracket at the head of the line, in order. The first one
            // that is not a timestamp and not a known tag ends the header.
            while index < line.endIndex, line[index] == "[" {
                guard let close = line[index...].firstIndex(of: "]") else { break }
                let body = String(line[line.index(after: index)..<close])
                if let seconds = timestamp(body) {
                    stamps.append(seconds)
                } else if let colon = body.firstIndex(of: ":") {
                    let key = String(body[body.startIndex..<colon]).lowercased()
                    let value = String(body[body.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "ti": title = value
                    case "ar": artist = value
                    case "al": album = value
                    // Milliseconds in the file, and signed the way the format
                    // means it: a positive offset says the words are late.
                    case "offset": offset = (Double(value) ?? 0) / 1000
                    default: break
                    }
                } else {
                    break
                }
                index = line.index(after: close)
            }

            guard !stamps.isEmpty else { continue }
            let words = String(line[index...]).trimmingCharacters(in: .whitespaces)
            for stamp in stamps { lines.append(Line(time: stamp, text: words)) }
        }

        guard !lines.isEmpty else { return nil }
        return Lyrics(
            title: title, artist: artist, album: album, offset: offset, lines: lines)
    }

    /// `mm:ss.xx`, `mm:ss.xxx` or `mm:ss`, or nil when it is not a time at all.
    static func timestamp(_ body: String) -> Double? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Double(parts[0]), minutes >= 0 else {
            return nil
        }
        let rest = parts[1]
        guard let seconds = Double(rest), seconds >= 0, seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }

    // MARK: Following along

    /// Which line is being sung at a given moment, or nil before the first one.
    ///
    /// A binary search rather than a scan: this is asked at the interface's
    /// frame rate against a file that can be several hundred lines, and the
    /// obvious loop is the kind of thing that costs nothing until somebody
    /// loads an opera.
    public func index(at seconds: Double) -> Int? {
        let time = seconds + offset
        guard let first = lines.first, time >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// How far through the current line the moment is, from 0 to 1.
    ///
    /// For a highlight that sweeps rather than jumps — which is the whole
    /// reason anybody wants synchronised lyrics rather than a printed sheet.
    /// The last line has no successor to measure against, so it is given four
    /// seconds, which is about a sung phrase.
    public func progress(at seconds: Double) -> Double {
        guard let index = index(at: seconds) else { return 0 }
        let time = seconds + offset
        let start = lines[index].time
        let end = index + 1 < lines.count ? lines[index + 1].time : start + 4
        guard end > start else { return 1 }
        return max(0, min(1, (time - start) / (end - start)))
    }
}
