import AppKit
import Foundation
import UserNotifications
import YunDesign

/// Tells somebody their audio broke while the window was closed.
///
/// This is a menu-bar application and closing the window no longer quits it,
/// which makes the window optional — and every warning in it invisible. A route
/// that dies, audio that starts breaking up, a microphone that vanishes: with
/// the window closed, all of it happened silently. The person finds out from
/// the people on the other end of the call, which is the worst messenger.
///
/// So the faults that matter post a notification — but only while no window is
/// showing them. A notification that duplicates a warning already on screen is
/// noise, and noise is how people turn notifications off.
/// Which faults have been spoken, and which are still on their way.
///
/// This is a plain value rather than state inside the class for one reason:
/// the class cannot be exercised at all in a process without an application
/// bundle, and the interesting path — authorisation refused, so the fault was
/// never actually said — only happens inside a callback from the notification
/// centre. Split out, the whole state machine can be driven directly, and a
/// test that walks it is measuring behaviour rather than reading the source
/// for a string.
struct BackgroundNoticeLedger: Equatable {
    /// Faults that reached the notification centre.
    private(set) var posted: Set<String> = []
    /// Faults past the guard and not yet handed over. Emptied either way, so a
    /// refused authorisation does not leave one marked as spoken.
    private(set) var announcing: Set<String> = []
    /// Rises once per route session, so a repeat of the same fault is a new
    /// entry rather than a replacement of the last one.
    private(set) var session: UInt64 = 0

    /// One notification per distinct fault key per route session: the second
    /// "audio broke up" adds nothing the first did not, and a stream of them
    /// buries the one that mattered. A warning already on screen is not
    /// repeated either — a notification duplicating the window is noise, and
    /// noise is how people turn notifications off.
    ///
    /// Both sets are consulted, not one. Handing a notice to the centre is not
    /// instantaneous: the first notice of a process waits on an authorisation
    /// callback. Without `announcing`, two faults in one turn would both pass
    /// the guard; without `posted`, a fault would speak on every occurrence.
    func mayAnnounce(key: String, windowIsVisible: Bool) -> Bool {
        !windowIsVisible && !posted.contains(key) && !announcing.contains(key)
    }

    /// Past the guard, not yet spoken.
    mutating func beginAnnouncing(_ key: String) {
        announcing.insert(key)
    }

    /// The centre has it. Now it counts as said.
    ///
    /// Ignored when the session has moved on. Handing over is not synchronous
    /// — the first notice of a process waits on an authorisation callback, and
    /// a route can be stopped and started inside that wait. Recorded blind,
    /// the old session's answer wrote into the new session's `posted`, and the
    /// fault it names could never speak again for the whole of that new
    /// session: the notice was silenced by a route it had nothing to do with.
    mutating func handedOver(_ key: String, from session: UInt64) {
        guard session == self.session else { return }
        announcing.remove(key)
        posted.insert(key)
    }

    /// It was never said, so it must not be remembered as said — the next one
    /// of its kind may find authorisation granted, or at worst spend one cheap
    /// no-op. Ignored across a session boundary for the same reason as above.
    mutating func refused(_ key: String, from session: UInt64) {
        guard session == self.session else { return }
        announcing.remove(key)
    }

    /// A new route session may speak about everything again.
    mutating func reset() {
        posted = []
        announcing = []
        session &+= 1
    }
}

@MainActor
final class BackgroundNotices {
    static let shared = BackgroundNotices()

    /// Whether this process can talk to the notification centre at all.
    ///
    /// `UNUserNotificationCenter.current()` throws an Objective-C exception —
    /// `bundleProxyForCurrentProcess is nil` — in a process without an
    /// application bundle, which is what the test runner is. The first test
    /// that drove three dropouts through the model took the whole suite down
    /// with it. An `.app` bundle is the thing the centre actually requires, so
    /// that is what is checked.
    nonisolated static let processCanPostNotifications =
        Bundle.main.bundleURL.pathExtension == "app"

    private var ledger = BackgroundNoticeLedger()
    private var authorisationRequested = false

    /// Forgets what has been posted, so the next route session can speak again.
    func reset() {
        ledger.reset()
    }

    /// Posts one notice, subject to the rule above.
    ///
    /// Authorisation is requested provisionally on first use: provisional
    /// delivery goes quietly to Notification Centre without the permission
    /// dialog, which is the right weight for a utility's fault reports —
    /// somebody who wants banners can promote them in System Settings.
    func announce(key: String, title: String, body: String) {
        guard Self.processCanPostNotifications else { return }
        let windowIsVisible = NSApp.windows.contains {
            $0.isVisible && ($0.title == "YunAudio" || $0.title.isEmpty == false)
        }
        guard ledger.mayAnnounce(key: key, windowIsVisible: windowIsVisible) else { return }
        // In flight, not spoken. It becomes spoken when the centre has it.
        ledger.beginAnnouncing(key)
        // Read out here rather than captured: the closure is `@Sendable` and
        // this actor's state is not for it to reach into.
        let session = ledger.session

        let deliver: @Sendable () -> Void = {
            // Fetched inside the closure rather than captured: the centre is
            // not Sendable, and `current()` is documented as returning the same
            // singleton from anywhere.
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    // The session is in the identifier, not just the key.
                    //
                    // Re-using one replaces the delivered notification rather
                    // than adding to it, so the second session's "the audio is
                    // breaking up" would quietly overwrite the first — and if
                    // the first had already been dismissed, there is a real
                    // chance the replacement never alerts at all. Each session's
                    // notice is its own.
                    identifier: "com.yuhuanstudio.yunaudio.\(key).\(session)",
                    content: content, trigger: nil))
        }
        let centre = UNUserNotificationCenter.current()
        if authorisationRequested {
            ledger.handedOver(key, from: session)
            deliver()
        } else {
            authorisationRequested = true
            centre.requestAuthorization(options: [.alert, .provisional]) {
                [weak self] granted, _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Either way it leaves the in-flight set. Refused means this
                    // fault was never said, so it must not be remembered as
                    // said — the next one of its kind may find authorisation
                    // granted, or at worst spend one cheap no-op.
                    guard granted else {
                        self.ledger.refused(key, from: session)
                        return
                    }
                    // Delivered either way — the fault did happen, and its
                    // identifier carries the session it happened in, so it
                    // cannot replace anything the new session has said.
                    self.ledger.handedOver(key, from: session)
                    deliver()
                }
            }
        }
    }
}
