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

    private var posted: Set<String> = []
    private var authorisationRequested = false

    /// Forgets what has been posted, so the next route session can speak again.
    func reset() { posted = [] }

    /// Posts one notice, subject to the rule above.
    ///
    /// Authorisation is requested provisionally on first use: provisional
    /// delivery goes quietly to Notification Centre without the permission
    /// dialog, which is the right weight for a utility's fault reports —
    /// somebody who wants banners can promote them in System Settings.
    func announce(key: String, title: String, body: String) {
        let windowIsVisible = NSApp.windows.contains {
            $0.isVisible && ($0.title == "YunAudio" || $0.title.isEmpty == false)
        }
        guard
            Self.shouldPost(
                windowIsVisible: windowIsVisible, alreadyPosted: posted, key: key)
        else { return }
        posted.insert(key)

        let deliver: @Sendable () -> Void = {
            // Fetched inside the closure rather than captured: the centre is
            // not Sendable, and `current()` is documented as returning the same
            // singleton from anywhere.
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "com.yuhuanstudio.yunaudio.\(key)",
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
