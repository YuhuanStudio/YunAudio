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
        /// Who sings this line, when the file says so — a performer's name, or
        /// 「合」 for both together. Never part of `text`.
        ///
        /// Duet files write this as a line of its own carrying nothing but the
        /// name, or as a prefix before a colon. Drawn as lyrics, as they were,
        /// the stage showed 「合」, 「王赫野」 and 「黃霄雲」 sitting between the
        /// words as though they were something to sing.
        public let singer: String?

        public init(
            time: Double, text: String, singer: String? = nil,
            syllables: [Syllable] = [], translation: String? = nil
        ) {
            self.time = time
            self.text = text
            self.singer = singer
            self.syllables = syllables
            self.translation = translation
        }

        /// The same line with a translation attached.
        public func translated(_ translation: String?) -> Line {
            Line(
                time: time, text: text, singer: singer, syllables: syllables,
                translation: translation)
        }

        /// How far through the line a moment is, using the word times when the
        /// file carried them and interpolating linearly within the word.
        ///
        /// Returns nil when there are none, so the caller can fall back rather
        /// than be handed a fabricated number that looks like a measurement.
        public func progress(at seconds: Double, lineEnd: Double) -> Double? {
            guard !syllables.isEmpty else { return nil }
            let total = max(0, text.count)
            guard total > 0 else { return nil }
            if seconds <= syllables[0].time { return 0 }

            var sung = 0
            for (index, syllable) in syllables.enumerated() {
                let start = syllable.time
                let end =
                    index + 1 < syllables.count
                    ? syllables[index + 1].time : max(lineEnd, start)
                if seconds >= end {
                    sung += syllable.text.count
                    continue
                }
                // Inside this word: its own characters fill across its own
                // span, so a long syllable fills slowly and a short one snaps.
                let span = end - start
                let within = span > 0 ? (seconds - start) / span : 1
                let filled = Double(syllable.text.count) * max(0, min(1, within))
                return max(0, min(1, (Double(sung) + filled) / Double(total)))
            }
            return 1
        }

        /// When each word starts, for files that say.
        ///
        /// Enhanced `.lrc` writes the timing inside the line —
        /// `[00:12.50]<00:12.50>These <00:12.90>are <00:13.20>words` — and the
        /// karaoke formats the Chinese services use carry the same information
        /// in their own syntax. Without it a sweep across a line can only be
        /// linear, which is a guess that is wrong for every line that does not
        /// hold its syllables evenly: the highlight arrives late on a long
        /// word and early on a short one, and a singer following it is pulled
        /// off the beat by the display.
        ///
        /// Empty when the file gave only a line time, in which case the linear
        /// sweep remains the honest approximation.
        public let syllables: [Syllable]

        public struct Syllable: Sendable, Hashable {
            /// Seconds from the start of the track.
            public let time: Double
            public let text: String

            public init(time: Double, text: String) {
                self.time = time
                self.text = text
            }
        }

        /// The same line in another language, when the index carried one.
        ///
        /// NetEase returns a second `.lrc` under `tlyric` and QQ an equivalent;
        /// this application has been asking for it since the day it was written
        /// and throwing it away. For a Chinese lyric in front of somebody who
        /// does not read Chinese — or an English one in front of somebody who
        /// does not read English — it is the difference between a stage that
        /// scrolls and a stage that means something.
        public let translation: String?

        /// A rest: the file marked time here and gave no words.
        ///
        /// Kept rather than dropped. An intro, an interlude and an outro are
        /// things a singer needs to see — how long until the next entry is the
        /// question a lyric sheet cannot answer and a stage can. Drawn as an
        /// empty line, as it was, it read as a gap in the layout instead.
        public var isInterlude: Bool { text.isEmpty }
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
    /// - Parameter performers: Names from the track being played. A duet file
    ///   marks who sings by putting a performer's name on a line of its own, and
    ///   nothing but the track's own credits distinguishes that from a lyric
    ///   that happens to be a name. Empty is safe: only the fixed markers and
    ///   the credit vocabulary are then recognised.
    public static func parse(_ text: String, performers: [String] = []) -> Lyrics? {
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
            let body = String(line[index...])
            let (words, syllables) = wordTimings(in: body)
            for stamp in stamps {
                lines.append(Line(time: stamp, text: words, syllables: syllables))
            }
        }

        guard !lines.isEmpty else { return nil }
        let sung = words(in: lines.sorted { $0.time < $1.time }, performers: performers)
        guard !sung.isEmpty else { return nil }
        return Lyrics(
            title: title, artist: artist, album: album, offset: offset, lines: sung)
    }

    /// Keeps what is sung and attributes the rest.
    ///
    /// Public indexes carry three things under the same timestamps: the words,
    /// the production credits, and who sings which part. Only the first is a
    /// lyric. Drawn without this, 「離開我的依賴」 put 「合」, 「王赫野」 and
    /// 「黃霄雲」 on the stage as lines of their own, and 「慢冷」 opened on two
    /// lines of marketing credits.
    static func words(in lines: [Line], performers: [String]) -> [Line] {
        let names = Set(
            performers
                .flatMap { $0.split(whereSeparator: { "/&,、，".contains($0) }) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        var kept: [Line] = []
        var pending: String?

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            // A rest, not a line to drop — but only one, and never before the
            // first word or after the last. Files pad with blank lines for the
            // look of the file as much as for the music, and a run of six of
            // them is not six rests.
            if text.isEmpty {
                if let last = kept.last, !last.isInterlude {
                    kept.append(Line(time: line.time, text: "", singer: nil))
                }
                continue
            }
            if isCredit(text) { continue }

            // A line that is nothing but a name marks who sings what follows.
            if let marker = singerMarker(text, names: names) {
                pending = marker
                continue
            }

            // The same thing written inline, which is the other convention.
            var body = text
            var singer = pending
            if let colon = body.firstIndex(where: { $0 == "：" || $0 == ":" }) {
                let head = String(body[body.startIndex..<colon])
                    .trimmingCharacters(in: .whitespaces)
                if let marker = singerMarker(head, names: names) {
                    singer = marker
                    body = String(body[body.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            guard !body.isEmpty else { continue }
            // Word times ride through the attribution pass. Rebuilt without
            // them, every enhanced file lost its timings here and the sweep
            // fell back to linear on exactly the files that had the data to do
            // better. Dropped when the text was rewritten — a singer prefix
            // lifted off the front — because the times then no longer describe
            // the characters that remain.
            kept.append(
                Line(
                    time: line.time, text: body, singer: singer,
                    syllables: body == text ? line.syllables : []))
        }
        // A trailing rest has nothing after it to wait for.
        while let last = kept.last, last.isInterlude { kept.removeLast() }
        return kept
    }

    /// Roles that introduce a credit rather than a lyric.
    ///
    /// Matched as a prefix before a colon, not as whole lines: the files write
    /// 「作詞：某某」 and 「營銷推廣：什麼洋 / 榮兒 @ 網益文化」 alike. Requiring a
    /// short head keeps a lyric that happens to contain a colon out of it.
    private static let creditRoles: Set<String> = [
        "作词", "作詞", "词", "詞", "作曲", "曲", "编曲", "編曲", "改编", "改編",
        "制作人", "製作人", "制作", "製作", "监制", "監製", "出品", "出品人",
        "联合出品", "聯合出品", "发行", "發行", "营销推广", "營銷推廣",
        "企划", "企劃", "统筹", "統籌", "音乐统筹", "音樂統籌", "乐队统筹", "樂隊統籌",
        "混音", "母带", "母帶", "录音", "錄音", "后期", "後期", "和声", "和聲",
        "吉他", "贝斯", "貝斯", "鼓", "键盘", "鍵盤", "弦乐", "弦樂", "配唱",
        "封面", "特别鸣谢", "特別鳴謝", "鸣谢", "鳴謝", "歌词", "歌詞",
        "音频编辑", "音頻編輯", "音乐制作", "音樂製作", "人声", "人聲",
        "op", "sp", "producer", "composer", "lyricist", "arranger",
        "mixing", "mixed by", "mastering", "mastered by", "produced by",
        "written by", "composed by", "arranged by", "lyrics by", "recorded by",
    ]

    static func isCredit(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }) else {
            return false
        }
        let head = String(text[text.startIndex..<colon])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        // A prefix, not the whole head. What the indexes actually send is the
        // role in two languages at once — 「作词 Lyricist : 翟雲鵬」, 「鼓Drum :
        // 郝稷倫」, 「後期母帶處理製作人MASTERING PRODUCER : …」 — so an exact
        // match caught none of the twenty credit lines at the head of a real
        // file. Long heads are still sentences rather than roles, but the cap
        // has to clear that last one.
        guard !head.isEmpty, head.count <= 40 else { return false }
        return creditRoles.contains { head.hasPrefix($0) }
    }

    /// Fixed duet markers, in both scripts. A performer's name is recognised
    /// only when the track itself names them.
    private static let singerMarkers: Set<String> = [
        "合", "男", "女", "齐", "齊", "对唱", "對唱", "合唱",
    ]

    static func singerMarker(_ text: String, names: Set<String>) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if singerMarkers.contains(trimmed) { return trimmed }
        return names.contains(trimmed) ? trimmed : nil
    }

    /// Splits an enhanced line into its words and their times.
    ///
    /// `<00:12.50>These <00:12.90>are <00:13.20>words` — the angle brackets are
    /// the enhanced `.lrc` convention, and a file that has none simply comes
    /// back as the whole line with no timings, which is the ordinary case.
    ///
    /// The text returned is the line without its markers, so everything
    /// downstream — the credit rule, the singer markers, the width the stage
    /// lays out — sees the words a person would read.
    static func wordTimings(in body: String) -> (text: String, syllables: [Syllable]) {
        guard body.contains("<") else {
            return (body.trimmingCharacters(in: .whitespaces), [])
        }
        var text = ""
        var syllables: [Syllable] = []
        var pending: Double?
        var index = body.startIndex

        while index < body.endIndex {
            if body[index] == "<", let close = body[index...].firstIndex(of: ">") {
                let inside = String(body[body.index(after: index)..<close])
                if let seconds = timestamp(inside) {
                    // A marker closes the word before it and opens the next.
                    pending = seconds
                    index = body.index(after: close)
                    continue
                }
            }
            let character = body[index]
            text.append(character)
            if let start = pending {
                syllables.append(Syllable(time: start, text: String(character)))
                pending = nil
            } else if var last = syllables.last {
                syllables.removeLast()
                last = Syllable(time: last.time, text: last.text + String(character))
                syllables.append(last)
            }
            index = body.index(after: index)
        }

        // Leading and trailing space is presentation, not a syllable.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == text.count else {
            return (trimmed, syllables.isEmpty ? [] : syllables)
        }
        return (trimmed, syllables)
    }

    public typealias Syllable = Line.Syllable

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

    /// Attaches a second `.lrc` of the same song in another language.
    ///
    /// Matched by timestamp rather than by position: the two files agree on
    /// when a line is sung and disagree on how many lines there are, because
    /// the translation routinely omits the credit block the original carries
    /// and sometimes merges two short lines into one. Pairing them by index —
    /// the obvious way — puts the wrong sentence under every line after the
    /// first mismatch, which is worse than showing none.
    ///
    /// A quarter of a second of tolerance, because the two are typed by
    /// different people from the same recording and agreeing to the frame is
    /// not something either promises.
    public func withTranslation(_ text: String) -> Lyrics {
        guard let other = Lyrics.parse(text) else { return self }
        var updated = self
        updated.lines = lines.map { line in
            let match = other.lines.min {
                abs($0.time - line.time) < abs($1.time - line.time)
            }
            guard let match, abs(match.time - line.time) <= 0.25,
                !match.text.isEmpty, match.text != line.text
            else { return line }
            return line.translated(match.text)
        }
        return updated
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
