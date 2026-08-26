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
@MainActor
final class BackgroundNotices {
    static let shared = BackgroundNotices()

    /// Whether to post, as a function of what decides it.
    ///
    /// One notification per distinct fault key per route session: the second
    /// "audio broke up" adds nothing the first did not, and a stream of them
    /// buries the one that mattered.
    nonisolated static func shouldPost(
        windowIsVisible: Bool, alreadyPosted: Set<String>, key: String
    ) -> Bool {
        !windowIsVisible && !alreadyPosted.contains(key)
    }

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

    private var posted: Set<String> = []
    private var authorisationRequested = false
    /// Rises once per route session, so a repeat of the same fault is a new
    /// entry rather than a replacement of the last one.
    private var session: UInt64 = 0

    /// Forgets what has been posted, so the next route session can speak again.
    func reset() {
        posted = []
        session &+= 1
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
        guard
            Self.shouldPost(
                windowIsVisible: windowIsVisible, alreadyPosted: posted, key: key)
        else { return }
        posted.insert(key)
        // Read out here rather than captured: the closure is `@Sendable` and
        // this actor's state is not for it to reach into.
        let session = session

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
            deliver()
        } else {
            authorisationRequested = true
            centre.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
                guard granted else { return }
                deliver()
            }
        }
    }
}
