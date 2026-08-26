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
        let ledger = BackgroundNoticeLedger()
        #expect(!ledger.mayAnnounce(key: "dropouts", windowIsVisible: true))
    }

    /// The case this exists for: the fault happened and nobody can see it.
    @Test("a closed window posts")
    func closedWindowPosts() {
        let ledger = BackgroundNoticeLedger()
        #expect(ledger.mayAnnounce(key: "dropouts", windowIsVisible: false))
    }

    /// The second "audio broke up" adds nothing the first did not.
    @Test("each fault speaks once")
    func eachFaultSpeaksOnce() {
        var ledger = BackgroundNoticeLedger()
        ledger.beginAnnouncing("dropouts")
        ledger.handedOver("dropouts", from: ledger.session)
        #expect(!ledger.mayAnnounce(key: "dropouts", windowIsVisible: false))
        // A different fault is a different thing to say.
        #expect(ledger.mayAnnounce(key: "route-stopped", windowIsVisible: false))
    }

    /// The window between the guard and the centre is not instantaneous — the
    /// first notice of a process waits on an authorisation callback — and two
    /// faults arriving inside it must not both pass.
    @Test("a notice in flight holds the guard shut")
    func inFlightHoldsTheGuard() {
        var ledger = BackgroundNoticeLedger()
        ledger.beginAnnouncing("dropouts")
        #expect(!ledger.mayAnnounce(key: "dropouts", windowIsVisible: false))
        #expect(ledger.posted.isEmpty, "nothing has reached the centre yet")
    }

    /// The defect this split exists for: marking a fault as spoken before
    /// knowing whether it was said. A refused authorisation left the fault
    /// recorded as posted, so it could never speak again for the whole session
    /// — the one path where the notification mattered most.
    @Test("a refused authorisation leaves the fault free to speak again")
    func refusalDoesNotCountAsSpoken() {
        var ledger = BackgroundNoticeLedger()
        ledger.beginAnnouncing("dropouts")
        ledger.refused("dropouts", from: ledger.session)
        #expect(ledger.posted.isEmpty, "it was never said")
        #expect(ledger.announcing.isEmpty, "and it is no longer in flight")
        #expect(ledger.mayAnnounce(key: "dropouts", windowIsVisible: false))
    }

    /// An answer that arrives after the route it belonged to has been replaced
    /// belongs to nothing.
    ///
    /// The authorisation callback is not synchronous, and a route can be
    /// stopped and started inside the wait. Recorded blind, the old session's
    /// answer landed in the new session's `posted` and silenced that fault for
    /// the whole of it — the notification killed by a route it never saw.
    @Test("a late answer does not silence the session that replaced it")
    func lateAnswerDoesNotCrossSessions() {
        var ledger = BackgroundNoticeLedger()
        let inFlight = ledger.session
        ledger.beginAnnouncing("route-stopped")
        ledger.reset()
        ledger.handedOver("route-stopped", from: inFlight)
        #expect(ledger.posted.isEmpty, "the new session has said nothing")
        #expect(ledger.mayAnnounce(key: "route-stopped", windowIsVisible: false))
        // And a refusal from the past cannot reach across either — here it
        // would have cleared an in-flight notice the new session owns.
        ledger.beginAnnouncing("route-stopped")
        ledger.refused("route-stopped", from: inFlight)
        #expect(!ledger.mayAnnounce(key: "route-stopped", windowIsVisible: false))
    }

    /// A new route session may speak about everything again, and under a new
    /// session number so the identifier does not replace the last one.
    @Test("a reset reopens every fault under a fresh session")
    func resetReopensEverything() {
        var ledger = BackgroundNoticeLedger()
        ledger.beginAnnouncing("dropouts")
        ledger.handedOver("dropouts", from: ledger.session)
        let before = ledger.session
        ledger.reset()
        #expect(ledger.session == before &+ 1)
        #expect(ledger.mayAnnounce(key: "dropouts", windowIsVisible: false))
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
