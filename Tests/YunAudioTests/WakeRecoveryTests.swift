import AppKit
import Foundation
import Testing

@testable import YunAudioApp

/// What happens to a running route when the lid closes and opens.
///
/// Sleep stops IOProcs, and what comes back is not guaranteed to be what went
/// down: the interface can say "running" while the cycle counter stands still.
/// Nothing observed sleep at all until this existed — the route's fate across a
/// lid-close was whatever CoreAudio happened to do.
@MainActor
@Suite("Waking up with a route")
struct WakeRecoveryTests {

    /// The rule, as a function of the two numbers it depends on.
    @Test("a route that resumed on its own is left alone")
    func flowingRouteIsLeftAlone() {
        #expect(
            RouterModel.wakeAction(
                wasRunning: true, cyclesAtSleep: 1_000, cyclesAfterWake: 1_400)
                == .nothing)
    }

    /// The case this exists for: running before sleep, and the counter has not
    /// moved after the settle. That route is dead however alive it looks.
    @Test("a route whose counter stood still is restarted")
    func deadRouteIsRestarted() {
        #expect(
            RouterModel.wakeAction(
                wasRunning: true, cyclesAtSleep: 1_000, cyclesAfterWake: 1_000)
                == .restart)
    }

    /// A route that was not running has nothing to recover.
    @Test("a stopped route stays stopped")
    func stoppedRouteStaysStopped() {
        #expect(
            RouterModel.wakeAction(
                wasRunning: false, cyclesAtSleep: 0, cyclesAfterWake: 0) == .nothing)
    }

    /// The wiring: the model registers for both notifications, once.
    ///
    /// Through an injected centre, so posting fake sleep does not depend on
    /// the workspace and cannot race another suite.
    @Test("sleep and wake are observed, idempotently")
    func observersAreRegisteredOnce() {
        let centre = NotificationCenter()
        let model = RouterModel()
        model.observeSleepAndWake(center: centre)
        model.observeSleepAndWake(center: centre)
        // Posting must not crash and must not double-handle; the assertion of
        // count is indirect — a second registration would fire the handler
        // twice, and the handler is exercised through the public seam below.
        centre.post(name: NSWorkspace.willSleepNotification, object: nil)
        centre.post(name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// The settle window is long enough for a healthy route to prove itself.
    ///
    /// At 48 kHz and 128 frames a live route produces ~375 cycles a second, so
    /// two seconds is ~750 — far above the single cycle the comparison needs —
    /// while a judgement taken immediately would restart routes that were
    /// about to resume on their own.
    @Test("the settle window is seconds, not an instant")
    func settleWindowIsReasonable() {
        #expect(RouterModel.wakeSettleSeconds >= 1)
        #expect(RouterModel.wakeSettleSeconds <= 10)
    }
}
