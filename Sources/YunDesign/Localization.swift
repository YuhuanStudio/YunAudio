import Foundation

/// Which language the interface is read in.
///
/// An explicit choice exists because following the system is often not what
/// somebody wants: a Mac set up in English by a person who reads Chinese is
/// ordinary, and macOS's own per-application language setting is buried
/// somewhere most people never find.
public enum YunLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// The `.lproj` folder this selects, or nil to follow the system.
    public var folder: String? { self == .system ? nil : rawValue }

    /// A language is named in itself and never translated: somebody hunting
    /// for their own language is looking for the word they would write, and a
    /// Chinese reader faced with an English interface would find nothing under
    /// "Traditional Chinese". Only the row that is a sentence rather than a
    /// name goes through `loc()`.
    public var title: String {
        switch self {
        case .system: loc("Follow the system")
        case .english: "English"
        case .traditionalChinese: "繁體中文"
        case .simplifiedChinese: "简体中文"
        }
    }
}

/// Looks a string up in the application's bundle.
///
/// Two problems make this less trivial than `NSLocalizedString`:
///
/// SwiftUI resolves a `Text` literal against the bundle of the module the view
/// lives in, and the views here are split across modules, so a literal in a
/// `YunDesign` component would look in the wrong place and silently fall
/// through to its key.
///
/// SwiftPM also lowercases the `.lproj` folder names it copies — `zh-Hant.lproj`
/// arrives as `zh-hant.lproj` — while `Bundle`'s own matching is case-sensitive.
/// A system set to `zh-Hant-TW` therefore finds nothing and quietly reads
/// English. So the right table is resolved here, case-insensitively, once.
///
/// And where the folders sit inside the bundle is not fixed either: a resource
/// bundle is flat under one toolchain and wrapped in `Contents/Resources`
/// under another. Looking in one place turned the whole Chinese interface back
/// into English, in a build that was otherwise correct and said nothing.
public enum YunStrings {
    /// Set at launch to the bundle carrying the `.lproj` folders.
    public nonisolated(unsafe) static var bundle: Bundle = .main {
        didSet { resolved = nil }
    }

    private nonisolated(unsafe) static var resolved: Bundle?

    /// Where the explicit choice is kept.
    ///
    /// Read straight out of `UserDefaults` rather than handed in at launch,
    /// because the first lookup can happen before anything has had a chance to
    /// hand anything in — the model is built while the application struct is
    /// still initialising — and a language that arrives one frame late is a
    /// window that opens in the wrong one.
    private static let defaultsKey = "com.yuhuanstudio.yunaudio.language"
    private nonisolated(unsafe) static var stored: YunLanguage?

    /// The language override. `.system` follows `Locale.preferredLanguages`,
    /// which is what this did unconditionally before.
    public static var language: YunLanguage {
        get {
            if let stored { return stored }
            let value =
                UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(YunLanguage.init(rawValue:)) ?? .system
            stored = value
            return value
        }
        set {
            guard newValue != language else { return }
            stored = newValue
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
            resolved = nil
        }
    }

    /// The bundle for the language the user actually reads, or the container
    /// itself when nothing better matches.
    private static func table() -> Bundle {
        if let resolved { return resolved }

        // Both layouts, in the order that costs least: `resourceURL` is right
        // for a wrapped bundle and the bundle path is right for a flat one.
        let roots = [bundle.resourceURL?.path, bundle.bundlePath].compactMap { $0 }
        var available: [(name: String, root: String)] = []
        for root in roots {
            let folders =
                (try? FileManager.default.contentsOfDirectory(atPath: root))?
                .filter { $0.hasSuffix(".lproj") } ?? []
            available += folders.map { (String($0.dropLast(6)), root) }
            if !available.isEmpty { break }
        }

        // Walk the user's preferences in order and take the first that matches
        // a folder, comparing without case and allowing "zh-Hant-TW" to select
        // "zh-hant" — a region variant should not fall all the way back to
        // English when the language is present.
        //
        // The explicit choice goes in front of the system's list rather than
        // replacing it: a stored language whose folder has since been dropped
        // from the bundle should fall through to what the system reads, not to
        // the untranslated keys.
        let order = (language.folder.map { [$0] } ?? []) + Locale.preferredLanguages
        for preferred in order {
            let wanted = preferred.lowercased()
            if let match = available.first(where: { $0.name.lowercased() == wanted })
                ?? available.first(where: { wanted.hasPrefix($0.name.lowercased()) })
                ?? available.first(where: { $0.name.lowercased().hasPrefix(wanted) }),
                let localized = Bundle(path: "\(match.root)/\(match.name).lproj")
            {
                resolved = localized
                return localized
            }
        }
        resolved = bundle
        return bundle
    }

    static func lookUp(_ key: String) -> String {
        table().localizedString(forKey: key, value: key, table: nil)
    }
}

/// Shorthand for a localised literal.
///
/// Short because it appears on almost every view line and anything longer
/// would be more visible than the string it wraps. Not `L`, which reads better
/// still but is not lower camel case and so fails the project's own lint.
///
/// The read of the theme's language is what makes switching language repaint
/// the running interface. SwiftUI has no idea that a plain function returns
/// something different than it did a moment ago, so without it the window
/// keeps every string it has already resolved until something else happens to
/// invalidate it — which is a setting that looks broken for as long as nobody
/// touches anything. Observation is only consulted on the main thread, where
/// the main actor is what `Thread.isMainThread` means; off it, this is the
/// lookup it always was.
public func loc(_ key: String) -> String {
    if Thread.isMainThread {
        onTheMainThread { _ = YunTheme.shared.language }
    }
    return YunStrings.lookUp(key)
}
