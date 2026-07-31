import Foundation
import YunDesign

/// Whether the words are shown as the file wrote them, or converted.
///
/// A Chinese catalogue is not one script. 網易雲 and QQ 音樂 return simplified
/// for songs a Taiwanese singer released in traditional, an `.lrc` beside the
/// file is whatever whoever made it typed, and the same song fetched from two
/// indexes can come back in two scripts on two evenings. Somebody reading along
/// does not want to find out which one they got.
///
/// ICU owns the systematic half of the conversion — 來→来, 愛→爱 — through the
/// `Hant-Hans` transform, which the title matcher has used for some time to
/// decide whether two spellings are the same song. This is the same transform
/// pointed at the words themselves.
///
/// A pure value, because what it must not do is the interesting part: it must
/// not touch romanisation, it must not touch a translation that is already in
/// another language, and it must leave a line that is not Chinese exactly as it
/// found it.
enum LyricScript: String, CaseIterable, Sendable {
    /// However the file or the index wrote it.
    case asWritten
    case simplified
    case traditional

    /// The setting's name in `UserDefaults`.
    static let defaultsKey = "YunAudioLyricScript"

    @MainActor var title: String {
        switch self {
        case .asWritten: loc("As written")
        case .simplified: loc("Simplified")
        case .traditional: loc("Traditional")
        }
    }

    /// The glyph on the button, which is the state it is in rather than the
    /// state it would move to — a control that shows its own destination is
    /// read backwards by half the people who press it.
    var mark: String {
        switch self {
        case .asWritten: "字"
        case .simplified: "简"
        case .traditional: "繁"
        }
    }

    /// One button, three states, in the order somebody would expect: leave it
    /// alone, simplify, traditionalise, back to leaving it alone.
    var next: Self {
        switch self {
        case .asWritten: .simplified
        case .simplified: .traditional
        case .traditional: .asWritten
        }
    }

    /// The words, converted.
    ///
    /// Empty in, empty out, and anything without Han characters passes through
    /// untouched — the transform is a no-op on Latin text, but checking first
    /// means an English song does not pay for a transform on every line of
    /// every redraw.
    func convert(_ text: String) -> String {
        guard self != .asWritten, !text.isEmpty, Self.containsHan(text) else { return text }
        let transform =
            self == .simplified
            ? StringTransform("Hant-Hans") : StringTransform("Hans-Hant")
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    /// Whether a line has anything worth converting.
    ///
    /// The unified CJK blocks and the compatibility ideographs. Deliberately not
    /// kana or hangul: a Japanese line carrying kanji is left alone, because
    /// "simplify this" is not a thing anybody means about Japanese.
    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}
