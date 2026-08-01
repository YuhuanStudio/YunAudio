import Foundation
import Testing

@testable import YunAudioApp

/// Switches somebody threw on purpose have to still be thrown next time.
///
/// Six were not. The KTV scoring switch, 重唱, the inspector tab, whether the
/// daemons are listed, and whether Apple's classifier is running were all reset
/// at every launch — so somebody who sings every evening found the scoring
/// switch off every evening, and the application always opened on a tab they
/// had not chosen.
///
/// Nothing had gone wrong; the fields were simply never added to `Preferences`.
/// That is the failure mode this guards: a setting is added, its control is
/// wired up, it works perfectly for the length of one launch, and no test
/// anywhere notices. Naming them here means the next one is a decision rather
/// than an oversight.
@Suite("what the application remembers about what you switched on")
struct RememberedSettingsTests {

    private var source: String {
        get throws {
            try String(
                contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                    + "Sources/YunAudioApp/Preferences.swift", encoding: .utf8)
        }
    }

    private var model: String {
        get throws {
            try String(
                contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                    + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        }
    }

    /// Every switch that has to survive a relaunch, and the field it is kept in.
    private static let remembered = [
        ("isScoringSinging", "isScoringSinging"),
        ("repeatsOneSong", "repeatsOneSong"),
        ("inspectorTab", "inspectorTab"),
        ("showsBackgroundApps", "showsBackgroundApps"),
        ("isSoundIdentificationEnabled", "isSoundIdentificationEnabled"),
    ]

    @Test("each one has somewhere to be kept")
    func hasAField() throws {
        let preferences = try source
        for (name, field) in Self.remembered {
            #expect(preferences.contains("var \(field):"), "\(name) has no Preferences field")
        }
    }

    @Test("each one is written when it changes")
    func isWritten() throws {
        let text = try model
        // In the snapshot `persist` builds. Reading it back out of the file is
        // the only way to check this without a running router and a real
        // preferences file on somebody's disk.
        for (_, field) in Self.remembered {
            #expect(text.contains("\(field):"), "\(field) is never handed to persist")
        }
    }

    @Test("each one is read back at launch")
    func isRestored() throws {
        let text = try model
        for (_, field) in Self.remembered {
            #expect(text.contains("saved.\(field)"), "\(field) is never read from the file")
        }
    }

    @Test("new fields are optional, so an older file still opens")
    func staysBackwardCompatible() throws {
        let preferences = try source
        for (_, field) in Self.remembered {
            let declaration = try #require(preferences.range(of: "var \(field):"))
            let line = preferences[declaration.lowerBound...].prefix(while: { $0 != "\n" })
            #expect(line.contains("?"), "\(field) is not optional: \(line)")
        }
    }

    @Test("the allocation tripwire is the stated exception")
    func theOneThatIsNotRemembered() throws {
        // Not an omission. The hook is process-wide and every allocation in
        // SwiftUI, AppKit and CoreAudio pays for it, so surviving a relaunch
        // would mean a machine that is quietly slower with nothing on screen to
        // say why. What matters is that the reason is written down where the
        // property is, rather than being indistinguishable from the six that
        // were forgotten.
        let text = try model
        #expect(!(try source).contains("var watchesIOAllocations:"))
        #expect(text.contains("deliberately **not** remembered across launches"))
    }
}

/// Wanting to be scored, which is not the same as being scored.
///
/// The two differ for the whole of a launch: `startScoring` needs a route and
/// there is none while preferences are being read, so throwing the switch there
/// only produces its refusal. The first version of this persisted that refusal
/// — so restoring the setting destroyed the very preference it had just read,
/// every launch, silently. Stored and then wiped by the act of reading it is
/// worse than never stored.
@Suite("wanting to be scored survives having nothing to score")
struct ScoringWishTests {

    private var model: String {
        get throws {
            try String(
                contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                    + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        }
    }

    @Test("the wish is what is written down, not the switch")
    func persistsTheWish() throws {
        #expect(try model.contains("isScoringSinging: wantsScoring,"))
    }

    @Test("and reading it back sets the wish rather than throwing the switch")
    func restoresTheWish() throws {
        let text = try model
        #expect(text.contains("wantsScoring = saved.isScoringSinging ?? false"))
        // The switch must not be assigned from the file: at that point in a
        // launch there is no route and the assignment is undone immediately.
        #expect(!text.contains("isScoringSinging = saved."))
    }

    @Test("the refusal does not count as somebody changing their mind")
    func refusalDoesNotPersist() throws {
        let text = try model
        // Both refusals in `startScoring` are bracketed, and the observer
        // returns before writing anything when they are.
        #expect(text.ranges(of: "isRefusingToScore = true").count == 2)
        #expect(text.contains("guard !isRefusingToScore else { return }"))
    }

    @Test("and the wish is spent when a route finally exists")
    func spentOnStart() throws {
        #expect(
            try model.contains("if wantsScoring, !isScoringSinging { isScoringSinging = true }")
        )
    }
}
