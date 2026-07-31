import Foundation

/// What a browser tab is playing, for the songs that are not in a music player.
///
/// YouTube is where a great deal of music actually gets played, and none of it
/// was reachable. `MediaRemote` would have covered every application at once
/// and was measured returning an empty dictionary on this machine — see
/// `NowPlaying` — so the route is the same one the two players already use: a
/// published scripting interface. Safari and Chrome both ship one, and both
/// can be asked to run a line of JavaScript in a tab.
///
/// **It needs a setting the person has to turn on**, and that is the honest
/// part of this. Safari hides it behind Develop ▸ Allow JavaScript from Apple
/// Events; Chrome behind View ▸ Developer ▸ Allow JavaScript from Apple
/// Events. Without it the event comes back with a specific error rather than
/// silence, so the panel can say which switch and where instead of showing
/// nothing and looking broken.
enum BrowserNowPlaying {

    /// The browsers asked, in order. Safari first: it is on every Mac.
    ///
    /// Everything after Chrome is a Chromium fork shipping Chrome's own
    /// scripting dictionary, so `execute … javascript` reaches them unchanged —
    /// see `script(forBrowser:javaScript:onlyTabAt:)`, which branches on Safari
    /// and treats everything else as Chromium.
    ///
    /// **None of the forks is installed on this machine, so none has been
    /// exercised here.** They are listed anyway because the cost of being wrong
    /// about one is nothing: a browser that is not installed never appears in
    /// `installedAutomationTargets`, one that is not running is skipped by
    /// `isPlayerRunning` before any event is sent, and one that refuses the
    /// script lands in the existing `javaScriptNotAllowed` path that names the
    /// switch to turn on. The cost of leaving them out is somebody's music
    /// being invisible for no reason.
    static let browsers: [(name: String, bundleID: String)] = [
        ("Safari", "com.apple.Safari"),
        ("Google Chrome", "com.google.Chrome"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Brave Browser", "com.brave.Browser"),
        ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Opera", "com.operasoftware.Opera"),
    ]

    /// The shortest thing worth calling a song.
    ///
    /// **Observed, on a real tab.** A YouTube mid-roll advert reported a
    /// duration of 11.07 seconds and a position of 10.24, and passed a guard
    /// that only asked for a finite duration greater than zero — so for those
    /// eleven seconds the stage would have taken the advert as the song, gone
    /// looking for its words, and thrown away the one it was on. Forty-five
    /// seconds is below any song and above every advert.
    static let shortestSong: Double = 45

    /// Field separator, matching the one the player scripts already use.
    static let separator = "\u{1F}"

    /// Reads the first tab that has a video element with a source loaded.
    ///
    /// **Measured against a real Safari, 2026-07-31.** The same sweep without
    /// these two guards answered from a GitHub project page: a `<video>` with
    /// no source, `currentTime` 0 and a duration of `NaN`, sitting in a README.
    /// Unguarded, that page would have become the song — a track with a
    /// nonsense length, a stage attached to it, and a lyric lookup for the
    /// title of a repository. Pages carry video elements that are not media.
    /// With the guards, the same browser answers "no tab".
    ///
    /// Written without a single backslash. This string is pasted into an
    /// AppleScript string literal, which has its own escaping, and a JavaScript
    /// escape surviving that intact is a coin toss — `String.fromCharCode(31)`
    /// says the same thing as an escape and cannot be eaten twice.
    static var readingScript: String {
        let separator = "String.fromCharCode(31)"
        return """
            (function(){\
            var v=document.querySelector('video');\
            if(!v||!v.src&&!v.currentSrc)return '';\
            if(!isFinite(v.duration)||v.duration<=0)return '';\
            var t=document.title.replace(/ - YouTube$/,'').replace(/^\\(\\d+\\) /,'');\
            var c='';\
            var e=document.querySelector('ytd-channel-name a,#upload-info a,#owner-name a');\
            if(e&&e.textContent)c=e.textContent.trim();\
            return [t,c,v.currentTime,v.duration,v.paused?'paused':'playing',location.href]\
            .join(\(separator));\
            })()
            """
    }

    /// Runs one line of JavaScript in whichever tab is playing.
    ///
    /// Every tab, not just the front one: music plays in a tab somebody left
    /// behind three windows ago, which is the whole reason this is worth
    /// having. The loop stops at the first tab that answers.
    static func script(
        forBrowser name: String, javaScript: String, onlyTabAt address: String? = nil
    ) -> String {
        let call =
            name == "Safari"
            ? "do JavaScript theCode in theTab"
            : "execute theTab javascript theCode"
        // Running the script in every tab is what finding the song costs, and
        // it is worth paying once. It is not worth paying twenty times a
        // second, which is what the position poll would have done: thirty tabs
        // is six hundred JavaScript evaluations a second to learn a number
        // that came from one of them. Once the address is known, every other
        // tab is skipped by a string comparison — the same sweep, without the
        // part that costs anything.
        let guardClause =
            address == nil
            ? ""
            : """
                            if (URL of theTab as text) is not theWanted then
                                    exit repeat
                                end if

                """
        let wanted =
            address.map { "set theWanted to \"" + escapedForAppleScript($0) + "\"\n" }
            ?? ""
        return """
            set theCode to "\(escapedForAppleScript(javaScript))"
            \(wanted)tell application "\(name)"
                if it is not running then return ""
                repeat with theWindow in windows
                    repeat with theTab in tabs of theWindow
                        try
            \(guardClause)                set theAnswer to (\(call)) as text
                            if theAnswer is not "" then return theAnswer
                        end try
                    end repeat
                end repeat
            end tell
            return ""
            """
    }

    /// Backslashes first, then quotes: the other order escapes the escapes.
    static func escapedForAppleScript(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// What one tab answered, or nil when the answer is not a track.
    ///
    /// Deliberately strict about duration. A tab reporting a duration of zero
    /// or an infinity is a live stream or an advert, and neither is a song to
    /// put words under.
    static func parse(_ reply: String, browser: String) -> NowPlaying.Track? {
        let fields = reply.components(separatedBy: separator)
        guard fields.count >= 6 else { return nil }
        let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        guard let position = Double(fields[2]), let duration = Double(fields[3]),
            position.isFinite, duration.isFinite, duration >= shortestSong
        else { return nil }

        // 「Artist - Title」 is how a music video is named on YouTube, and the
        // channel is usually the artist's own. Splitting gives a title that
        // matches a lyric index; leaving it whole does not.
        let channel = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let (song, artist) = splitTitle(title, channel: channel)

        return NowPlaying.Track(
            application: browser, title: song, artist: artist, album: "",
            performers: artist.isEmpty ? [] : [artist],
            position: position, duration: duration,
            isPlaying: fields[4] == "playing",
            artworkURL: artworkURL(forTab: fields[5]),
            identity: fields[5])
    }

    /// Separates 「Artist - Title」 where a video is named that way.
    ///
    /// **Rewritten against real titles, taken from YouTube's own oEmbed.** The
    /// first version was written from what a title looks like in the
    /// imagination, and all three of the first three real ones defeated it:
    ///
    ///   · 「Huang Xiaoyun 黄霄雲 – The Rainy Season of a Youthful Crush
    ///     《年少心动雨季》Live | Shangyu 2026」
    ///   · 「周杰倫 Jay Chou【稻香 Rice Field】-Official Music Video」
    ///   · 「尤雅 - 往事只能回味『春風又吹紅了花蕊 …』【動態歌詞/Vietsub/Pinyin Lyrics】」
    ///
    /// The song's own name is inside the brackets in the first two and outside
    /// them in the third; the decoration is in brackets, after a bar, after a
    /// hyphen, and in a quoted line of the lyric itself. What they have in
    /// common is not a shape, so this is a sequence of removals ending in one
    /// preference, and each step is pinned to one of those three strings.
    ///
    /// **The strings it produces were then put to a real index.** All three
    /// find their song by name as the top answer. The second is the warning:
    /// 「稻香 / 周杰倫」 returns a 184-second upload by a re-poster before the
    /// 223-second original, so a title that matches is not a match — which is
    /// what the duration test in `OnlineLyrics.strongest` is for, and why a
    /// browser track carries the tab's own `duration` rather than only a name.
    /// It also crosses the scripts without anybody arranging it: the tab says
    /// 周杰倫 and the index holds 周杰伦, folded by the `Hant-Hans` transform
    /// added earlier for 「來不及愛你」.
    static func splitTitle(_ title: String, channel: String) -> (title: String, artist: String) {
        let cleaned = strippedDecoration(title)
        // The name in brackets wins where there is one: an uploader who writes
        // 《年少心动雨季》 or 【稻香 Rice Field】 is naming the song inside its own
        // punctuation, and everything round it is theirs rather than the
        // song's.
        if let named = bracketedName(in: cleaned) {
            let artist = cleaned.range(of: named).map {
                String(cleaned[..<$0.lowerBound])
            } ?? ""
            return (
                preferringHan(named),
                preferringHan(creditedName(in: artist, or: channel))
            )
        }
        for separator in [" - ", " – ", " — ", " ‐ "] {
            guard let range = cleaned.range(of: separator) else { continue }
            let artist = String(cleaned[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let song = String(cleaned[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !song.isEmpty {
                // A name inside the song half still wins — 「五月天 - 【溫柔】…」
                // — and anything else in brackets goes before the Chinese is
                // preferred, or the longest run of it would be a tagline.
                let named = bracketedName(in: song)
                return (
                    preferringHan(named ?? withoutBracketGroups(song)),
                    preferringHan(withoutBracketGroups(artist))
                )
            }
        }
        return (preferringHan(cleaned), preferringHan(creditedName(in: "", or: channel)))
    }

    /// The credit written before the song, or the channel when there is none.
    private static func creditedName(in prefix: String, or channel: String) -> String {
        // Bracket groups first: 「【纯享版】《」 in front of the song's name is
        // a label the programme put there, not a person, and trimming only the
        // marks would have left 「纯享版」 standing in as the artist.
        let trimmed = withoutBracketGroups(prefix).trimmingCharacters(
            // The opening mark of whatever bracket the name was taken out of
            // belongs to the bracket, not to the person: 「YOASOBI「」 is a
            // channel called YOASOBI with a quote mark stuck to it.
            in: CharacterSet(charactersIn: " -–—‐《》【】「」『』()（）").union(.whitespaces))
        // A sentence is not a credit, and neither is a paragraph. The tab that
        // was open said 「苦情歌天后遇上新生代實力Vocal！張碧晨徐子未心碎演繹
        // 《情結》…」 — the song's name is right there in the brackets and
        // everything before it is a presenter's line. Taken as the artist it
        // becomes twelve characters of advertising in a lyric query.
        // Length is not the test — 「Huang Xiaoyun 黄霄雲 – The Rainy Season of
        // a Youthful Crush」 is a long credit and a real one, and the Chinese
        // preference below reduces it to 黄霄雲. Punctuation is the test: a
        // presenter's line has some and a name does not.
        let isName =
            !trimmed.isEmpty
            && trimmed.rangeOfCharacter(
                from: CharacterSet(charactersIn: "，。！？、；：,;!?")) == nil
        if isName { return trimmed }
        // YouTube appends 「 - Topic」 to the channels it generates, and no
        // lyric index has heard of an artist called that.
        return channel.hasSuffix(" - Topic")
            ? String(channel.dropLast(" - Topic".count)) : channel
    }

    /// The name an uploader put inside 《》 or 【】, when it is short enough to
    /// be a name rather than a sentence.
    static func bracketedName(in title: String) -> String? {
        for pattern in [
            "《([^》]{1,24})》", "【([^】]{1,24})】",
            // Japanese titles are quoted, not bracketed: 「夜に駆ける」. Treating
            // these as lyric quotes and deleting them removed the song's name
            // and left 「YOASOBI Official Music Video」.
            "「([^」]{1,24})」", "『([^』]{1,24})』",
        ] {
            guard let match = title.range(of: pattern, options: .regularExpression)
            else { continue }
            let inner = title[match].dropFirst().dropLast()
            let name = inner.trimmingCharacters(in: .whitespaces)
            // A sentence is not a name. 「慢冷的人啊，會自我折磨」 is eleven
            // characters and fits every other test — it is a tagline the
            // uploader wrote, and taking it would have made the song's name a
            // line of advertising. Sentence punctuation is what tells them
            // apart.
            guard !name.isEmpty,
                name.rangeOfCharacter(from: CharacterSet(charactersIn: "，。！？、；：,;")) == nil
            else { continue }
            return name
        }
        return nil
    }

    /// Whatever is left in brackets once the name has been chosen.
    ///
    /// 「慢冷 Slow-To-Cool-Down【慢冷的人啊，會自我折磨】」 is the song plus a
    /// tagline, and the tagline has the longer run of Chinese in it — so
    /// without this the preference below would have picked the advertising.
    static func withoutBracketGroups(_ text: String) -> String {
        var cleaned = text
        for pattern in ["《[^》]*》", "【[^】]*】", "「[^」]*」", "『[^』]*』", "\\([^)]*\\)"] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: " ", options: .regularExpression)
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// Where a string carries both Chinese and Latin, the Chinese.
    ///
    /// 「周杰倫 Jay Chou」 and 「稻香 Rice Field」 are one name and one song with a
    /// gloss attached for people who do not read the other script. A lyric
    /// index holds one of the two, and it is the one the song was released
    /// under. A title with no Han in it is left exactly as it is.
    static func preferringHan(_ text: String) -> String {
        var runs: [String] = []
        var current = ""
        for character in text {
            let isHan = character.unicodeScalars.contains {
                (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
            }
            if isHan || (!current.isEmpty && (character.isNumber || character.isWhitespace)) {
                current.append(character)
            } else {
                runs.append(current)
                current = ""
            }
        }
        runs.append(current)
        let best = runs.map { $0.trimmingCharacters(in: .whitespaces) }
            .max { $0.count < $1.count } ?? ""
        return best.isEmpty ? text.trimmingCharacters(in: .whitespaces) : best
    }

    /// Removes what an uploader puts round a title and a lyric index will not
    /// match.
    static func strippedDecoration(_ title: String) -> String {
        var cleaned = title
        for pattern in [
            // A quoted line of the lyric, which uploaders use as a subtitle —
            // long, unlike a Japanese title in the same punctuation, which is
            // why the length is what separates them rather than the marks.
            "[『「][^』」]{25,}[』」]",
            // Bracket groups that are about the upload rather than the song.
            "\\s*[\\(\\[（【][^\\)\\]）】]*"
                + "(?i:official|mv|m/v|hd|4k|lyric|audio|video|live|vietsub|pinyin"
                + "|字幕|歌詞|歌词|完整版|高音質|高音质|純享|纯享|官方|伴奏)"
                + "[^\\)\\]）】]*[\\)\\]）】]",
            // Everything after a bar: 「| Shangyu 2026」, 「| 官方版」.
            "\\s*\\|.*$",
            // A tail after a hyphen that is about the upload.
            "\\s*[-–—‐]\\s*(?i:official|full|hd|4k|mv|m/v|lyrics?|audio|video|live)"
                + "[^《【]*$",
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return cleaned.trimmingCharacters(
            in: CharacterSet(charactersIn: " -–—‐").union(.whitespaces))
    }

    /// The same tab, asked only where it is — twenty times a second.
    ///
    /// A separate, smaller question from `readingScript` because it is asked
    /// two hundred times for every one of those: no title, no channel, no
    /// regular expressions, three fields.
    static var positionScript: String {
        let separator = "String.fromCharCode(31)"
        return """
            (function(){            var v=document.querySelector('video');            if(!v||!isFinite(v.duration)||v.duration<=0)return '';            return [location.href,v.currentTime,v.paused?'paused':'playing']            .join(\(separator));            })()
            """
    }

    /// Identity, position and state from one tab's answer.
    static func parsePosition(_ reply: String) -> (identity: String, seconds: Double, isPlaying: Bool)? {
        let fields = reply.components(separatedBy: separator)
        guard fields.count >= 3, let seconds = Double(fields[1]), seconds.isFinite
        else { return nil }
        return (fields[0], seconds, fields[2] == "playing")
    }

    /// The picture YouTube keeps for a video, from the address of the tab.
    ///
    /// Free, in the sense that matters: no request is made to find it out, the
    /// identifier is in the URL the tab already reported. Without it a song
    /// played from a browser is the one kind of song with no cover behind the
    /// words, which is exactly the arrangement the stage is built around.
    static func artworkURL(forTab address: String) -> URL? {
        guard let components = URLComponents(string: address),
            let host = components.host, host.contains("youtu")
        else { return nil }
        let identifier =
            components.queryItems?.first(where: { $0.name == "v" })?.value
            ?? (host.contains("youtu.be") ? String(components.path.dropFirst()) : nil)
        guard let identifier, !identifier.isEmpty,
            identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        // `hqdefault` rather than `maxresdefault`: every video has one, and the
        // stage blurs it to a wash and draws it at 256 points anyway.
        return URL(string: "https://i.ytimg.com/vi/\(identifier)/hqdefault.jpg")
    }

    /// JavaScript for one transport verb, or nil where a tab cannot do it.
    ///
    /// Previous and next are the player's own buttons, because a tab has no
    /// queue of its own — what "next" means on YouTube is whatever the page
    /// says it is, and reaching for the button is asking the page.
    static func script(for transport: NowPlaying.Transport) -> String? {
        switch transport {
        case .playPause:
            return "(function(){var v=document.querySelector('video');"
                + "if(!v)return '';if(v.paused){v.play()}else{v.pause()}return 'ok'})()"
        case .next:
            return "(function(){var b=document.querySelector('.ytp-next-button');"
                + "if(!b)return '';b.click();return 'ok'})()"
        case .previous:
            return "(function(){var b=document.querySelector('.ytp-prev-button');"
                + "if(!b)return '';b.click();return 'ok'})()"
        }
    }

    /// JavaScript that moves the tab's video to a moment.
    static func seekScript(toSeconds seconds: Double) -> String {
        let bounded = max(0, seconds.isFinite ? seconds : 0)
        return "(function(){var v=document.querySelector('video');"
            + "if(!v)return '';v.currentTime=\(String(format: "%.3f", bounded));return 'ok'})()"
    }
}
