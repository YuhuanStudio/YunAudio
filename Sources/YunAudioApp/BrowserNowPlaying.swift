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
    static let browsers: [(name: String, bundleID: String)] = [
        ("Safari", "com.apple.Safari"),
        ("Google Chrome", "com.google.Chrome"),
    ]

    /// Field separator, matching the one the player scripts already use.
    static let separator = "\u{1F}"

    /// Reads the first tab that has a video element with a source loaded.
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
    static func script(forBrowser name: String, javaScript: String) -> String {
        let call =
            name == "Safari"
            ? "do JavaScript theCode in theTab"
            : "execute theTab javascript theCode"
        return """
            set theCode to "\(escapedForAppleScript(javaScript))"
            tell application "\(name)"
                if it is not running then return ""
                repeat with theWindow in windows
                    repeat with theTab in tabs of theWindow
                        try
                            set theAnswer to (\(call)) as text
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
            position.isFinite, duration.isFinite, duration > 0
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
    /// Only on a hyphen with space either side, and only when both halves have
    /// something in them: 「Wonderwall」 must not become 「Wonder」 and 「wall」,
    /// and a title containing a dash mid-word is not a credit.
    static func splitTitle(_ title: String, channel: String) -> (title: String, artist: String) {
        let cleaned = strippedDecoration(title)
        for separator in [" - ", " – ", " — ", " ‐ "] {
            guard let range = cleaned.range(of: separator) else { continue }
            let artist = String(cleaned[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let song = String(cleaned[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !song.isEmpty { return (song, artist) }
        }
        // The channel, less the 「 - Topic」 YouTube appends to the automatic
        // ones, which is a label rather than part of anybody's name.
        let performer =
            channel.hasSuffix(" - Topic")
            ? String(channel.dropLast(" - Topic".count)) : channel
        return (cleaned, performer)
    }

    /// Removes what an uploader puts round a title and a lyric index will not
    /// match: 【】, official-video tags, quality claims.
    static func strippedDecoration(_ title: String) -> String {
        var cleaned = title
        for pattern in [
            "\\s*[\\(\\[（【][^\\)\\]）】]*(?i:official|mv|m/v|hd|4k|lyric|audio|video|字幕|歌詞|完整版)[^\\)\\]）】]*[\\)\\]）】]"
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
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
