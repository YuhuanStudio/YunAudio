import Foundation

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
public enum YunStrings {
    /// Set at launch to the bundle carrying the `.lproj` folders.
    public nonisolated(unsafe) static var bundle: Bundle = .main {
        didSet { resolved = nil }
    }

    private nonisolated(unsafe) static var resolved: Bundle?

    /// The bundle for the language the user actually reads, or the container
    /// itself when nothing better matches.
    private static func table() -> Bundle {
        if let resolved { return resolved }

        let available =
            (try? FileManager.default.contentsOfDirectory(
                atPath: bundle.bundlePath))?
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(6)) } ?? []

        // Walk the user's preferences in order and take the first that matches
        // a folder, comparing without case and allowing "zh-Hant-TW" to select
        // "zh-hant" — a region variant should not fall all the way back to
        // English when the language is present.
        for preferred in Locale.preferredLanguages {
            let wanted = preferred.lowercased()
            if let match = available.first(where: { $0.lowercased() == wanted })
                ?? available.first(where: { wanted.hasPrefix($0.lowercased()) })
                ?? available.first(where: { $0.lowercased().hasPrefix(wanted) }),
                let path = bundle.path(forResource: match, ofType: "lproj"),
                let localized = Bundle(path: path)
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
/// Named for brevity because it appears on almost every view line; anything
/// longer would be more visible than the string it wraps.
public func L(_ key: String) -> String { YunStrings.lookUp(key) }
