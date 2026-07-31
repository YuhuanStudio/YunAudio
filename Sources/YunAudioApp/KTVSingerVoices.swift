import AppKit
import SwiftUI
import YunAudioEngine

/// Which voice a line belongs to, as a colour.
///
/// A duet file says who sings each line, and until now that fact reached the
/// stage as a small caption above the line where the hand changes. That is the
/// information without the thing it is for: in every KTV machine ever built
/// the *line* is coloured, because somebody singing the second part needs to
/// see at a glance which of the next four lines are theirs, and reading a
/// caption is not a glance.
///
/// A pure value keyed on the song rather than a colour chosen per line, so the
/// same singer keeps the same colour for the whole song however the file
/// spells their name, and so the mapping can be asserted without a window.
struct KTVSingerVoices: Equatable, Sendable {

    /// Distinct singers, in the order the song first gives them a line.
    ///
    /// Order of appearance rather than alphabetical: the first voice heard is
    /// the one a listener thinks of as the first voice, and a song that opens
    /// on 王赫野 should not colour him second because 黃霄雲 sorts earlier.
    private let voices: [String]

    /// Tuned for a dark stage carrying a blurred cover: saturated enough to
    /// separate at a glance across a room, light enough to stay legible over a
    /// bright sleeve. Four, because a file with five distinct soloists is a
    /// concert recording and cycling is a better answer there than inventing
    /// colours nobody can tell apart.
    ///
    /// Adaptive, because the same mapping now serves the compact inspector,
    /// which is white in the light appearance: pastels chosen to glow on black
    /// are illegible there, so the light side is the same four hues taken down
    /// to where they read as ink.
    static let palette: [Color] = [
        adaptive(
            light: Color(red: 0.62, green: 0.36, blue: 0.02),
            dark: Color(red: 1.00, green: 0.76, blue: 0.42)),
        adaptive(
            light: Color(red: 0.08, green: 0.36, blue: 0.66),
            dark: Color(red: 0.56, green: 0.81, blue: 1.00)),
        adaptive(
            light: Color(red: 0.10, green: 0.45, blue: 0.22),
            dark: Color(red: 0.66, green: 0.94, blue: 0.73)),
        adaptive(
            light: Color(red: 0.58, green: 0.20, blue: 0.52),
            dark: Color(red: 0.96, green: 0.68, blue: 0.90)),
    ]

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(dark) : NSColor(light)
            })
    }

    /// Names a file uses for "everybody", which take no colour at all.
    ///
    /// White is what the stage draws when it does not know, and a chorus is
    /// exactly the line that belongs to no single voice — colouring it as a
    /// fifth singer would say the opposite of what it means.
    static let chorusNames: Set<String> = [
        "合", "合唱", "齊", "齐", "众", "眾", "all", "both", "chorus", "together",
    ]

    init(_ lyrics: Lyrics?) {
        var seen: Set<String> = []
        var order: [String] = []
        for line in lyrics?.lines ?? [] {
            guard let singer = line.singer?.trimmingCharacters(in: .whitespaces),
                !singer.isEmpty,
                !Self.chorusNames.contains(singer.lowercased()),
                !seen.contains(singer)
            else { continue }
            seen.insert(singer)
            order.append(singer)
        }
        voices = order
    }

    /// Whether colouring lines would say anything at all.
    ///
    /// One voice is not a duet, and tinting every line of a solo song amber
    /// only makes the stage yellow. The whole feature is the *contrast*.
    var isDuet: Bool { voices.count > 1 }

    /// The colour for a line, or nil where the stage's own white is right —
    /// no singer named, a chorus line, or a song sung by one person.
    func colour(for singer: String?) -> Color? {
        guard isDuet,
            let singer = singer?.trimmingCharacters(in: .whitespaces),
            let index = voices.firstIndex(of: singer)
        else { return nil }
        return Self.palette[index % Self.palette.count]
    }
}
