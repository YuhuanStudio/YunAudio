import Foundation
import Testing

@testable import YunAudioApp

/// When a fault is worth a system notification.
///
/// This is a menu-bar application whose window is optional, so every warning in
/// the window is optional too. The rule here is what keeps the notifications
/// honest: they speak only when nothing else is speaking, and once per fault —
/// noise is how people turn notifications off, and off is worse than none.
@Suite("Speaking up while the window is closed")
struct BackgroundNoticesTests {

    /// A warning already on screen is not repeated as a banner.
    @Test("a visible window keeps the notification quiet")
    func visibleWindowStaysQuiet() {
        #expect(
            !BackgroundNotices.shouldPost(
                windowIsVisible: true, alreadyPosted: [], key: "dropouts"))
    }

    /// The case this exists for: the fault happened and nobody can see it.
    @Test("a closed window posts")
    func closedWindowPosts() {
        #expect(
            BackgroundNotices.shouldPost(
                windowIsVisible: false, alreadyPosted: [], key: "dropouts"))
    }

    /// The second "audio broke up" adds nothing the first did not.
    @Test("each fault speaks once")
    func eachFaultSpeaksOnce() {
        #expect(
            !BackgroundNotices.shouldPost(
                windowIsVisible: false, alreadyPosted: ["dropouts"], key: "dropouts"))
        #expect(
            BackgroundNotices.shouldPost(
                windowIsVisible: false, alreadyPosted: ["dropouts"], key: "route-stopped"))
    }

    /// A repeat of the same fault in a later session is a new entry.
    ///
    /// Re-using a notification identifier replaces what was delivered rather
    /// than adding to it, so the second session's warning would overwrite the
    /// first — and a replacement of something already dismissed may never
    /// alert. The identifier carries the session for that reason.
    @Test("the identifier carries the session, not only the fault")
    func identifierCarriesTheSession() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/BackgroundNotices.swift", encoding: .utf8)
        #expect(source.contains(#"yunaudio.\(key).\(session)"#))
        #expect(source.contains("session &+= 1"))
    }

    /// The hooks exist where the faults happen, and the reset where a new
    /// route session begins — one per site, so a rename cannot silently orphan
    /// one.
    @Test("the fault sites announce and the start resets")
    func faultSitesAreWired() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        for key in ["dropouts", "route-stopped", "start-overdue"] {
            #expect(
                source.contains("key: \"\(key)\""), "no announcement for \(key)")
        }
        #expect(source.contains("BackgroundNotices.shared.reset()"))
    }
}

@MainActor
@Suite("The notice centre and the test runner")
struct BackgroundNoticesProcessTests {

    /// The guard this suite exists in: `UNUserNotificationCenter.current()`
    /// throws `bundleProxyForCurrentProcess is nil` in a bundle-less process,
    /// and the first test that drove three dropouts through the model brought
    /// the whole suite down as an uncaught NSException.
    @Test("a bundle-less process does not touch the notification centre")
    func bundlelessProcessIsGuarded() {
        #expect(!BackgroundNotices.processCanPostNotifications)
        // And announcing from here must be a no-op rather than a crash —
        // which this call is the proof of.
        BackgroundNotices.shared.announce(
            key: "test", title: "test", body: "test")
    }
}
