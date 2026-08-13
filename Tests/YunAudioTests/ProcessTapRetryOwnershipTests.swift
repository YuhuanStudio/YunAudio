import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Process-tap ownership across route retries")
struct ProcessTapRetryOwnershipTests {
    private final class Tap {
        let uid: String

        init(_ uid: String) {
            self.uid = uid
        }
    }

    private func recordDestruction(
        _ taps: [Tap], counts: inout [String: Int]
    ) {
        for tap in taps { counts[tap.uid, default: 0] += 1 }
    }

    @Test("an internal retry preserves every tap and destroys none")
    func retryPreservesTaps() {
        let first = Tap("tap-1")
        let second = Tap("tap-2")
        var ownership = ProcessTapRetryOwnership(
            active: [first, second], pending: [second])

        let retry = ownership.tearingDown(preserving: [first, second, first])

        #expect(retry.destroy.count == 0)
        #expect(retry.next.active.count == 0)
        #expect(retry.next.pending.count == 2)
        #expect(Set(retry.next.pending.map(\.uid)) == ["tap-1", "tap-2"])

        ownership = retry.next.activating([first, second])
        #expect(ownership.active.count == 2)
        #expect(ownership.pending.count == 0)
        #expect(ownership.allLive.count == 2)
    }

    @Test("a final stop destroys each active tap exactly once")
    func finalStopDestroysOnce() {
        let first = Tap("tap-1")
        let second = Tap("tap-2")
        var ownership = ProcessTapRetryOwnership(active: [first, second, first])
        var destructionCounts: [String: Int] = [:]

        let finalStop = ownership.tearingDown(preserving: [])
        recordDestruction(finalStop.destroy, counts: &destructionCounts)
        ownership = finalStop.next

        let repeatedStop = ownership.tearingDown(preserving: [])
        recordDestruction(repeatedStop.destroy, counts: &destructionCounts)

        #expect(finalStop.destroy.count == 2)
        #expect(repeatedStop.destroy.count == 0)
        #expect(destructionCounts == ["tap-1": 1, "tap-2": 1])
        #expect(ownership.allLive.count == 0)
    }

    @Test("a failed unstarted attempt destroys each pending tap exactly once")
    func finalFailureDestroysOnce() {
        let first = Tap("tap-1")
        let second = Tap("tap-2")
        var ownership = ProcessTapRetryOwnership<Tap>()
            .adopting([first, second, first])
        var destructionCounts: [String: Int] = [:]

        let failure = ownership.tearingDown(preserving: [])
        recordDestruction(failure.destroy, counts: &destructionCounts)
        ownership = failure.next

        let repeatedFailure = ownership.tearingDown(preserving: [])
        recordDestruction(repeatedFailure.destroy, counts: &destructionCounts)

        #expect(failure.destroy.count == 2)
        #expect(repeatedFailure.destroy.count == 0)
        #expect(destructionCounts == ["tap-1": 1, "tap-2": 1])
        #expect(ownership.pending.count == 0)
    }

    @Test("clock recovery never gives a destroyed UID to the next aggregate")
    func recoveryUsesOnlyLiveTaps() {
        let first = Tap("tap-1")
        let second = Tap("tap-2")
        let abandoned = Tap("old-pending")
        let ownership = ProcessTapRetryOwnership(
            active: [first, second], pending: [abandoned])

        let recovery = ownership.tearingDown(preserving: [first, second])
        let destroyedUIDs = Set(recovery.destroy.map(\.uid))
        let aggregateUIDs = Set(recovery.next.pending.map(\.uid))
        let activeRecovery = recovery.next.activating([first, second])

        #expect(recovery.destroy.count == 1)
        #expect(destroyedUIDs == ["old-pending"])
        #expect(aggregateUIDs == ["tap-1", "tap-2"])
        #expect(destroyedUIDs.isDisjoint(with: aggregateUIDs))
        #expect(activeRecovery.active.count == 2)
        #expect(activeRecovery.pending.count == 0)
    }

    @Test("structural lint wires internal and final teardown to different transitions")
    func engineUsesTheOwnershipBoundary() throws {
        // The four tests above execute the ownership state machine and assert
        // exact destruction counts and disjoint live/dead identities. This
        // source lint checks only that RoutingEngine calls those transitions at
        // retry, terminal Stop and clock-recovery boundaries.
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let lockedStart = try #require(source.range(of: "private func startLocked("))
        let attemptStart = try #require(
            source.range(
                of: "private func startAttempt(",
                range: lockedStart.upperBound..<source.endIndex))
        let stopStart = try #require(
            source.range(
                of: "private func stopLocked(",
                range: attemptStart.upperBound..<source.endIndex))
        let recoveryStart = try #require(
            source.range(
                of: "private func recoverFromClockLockLoss(",
                range: stopStart.upperBound..<source.endIndex))

        let locked = source[lockedStart.lowerBound..<attemptStart.lowerBound]
        let attempt = source[attemptStart.lowerBound..<stopStart.lowerBound]
        let stop = source[stopStart.lowerBound..<recoveryStart.lowerBound]
        let recovery = source[recoveryStart.lowerBound...]

        let adoption = try #require(
            locked.range(of: "adoptTapsForTeardownLocked(configuration.taps)"))
        let firstAttempt = try #require(locked.range(of: "try startAttempt("))
        let firstAttemptEnd = try #require(
            locked.range(
                of: "return",
                range: firstAttempt.upperBound..<locked.endIndex))
        let firstAttemptCall = locked[firstAttempt.lowerBound..<firstAttemptEnd.lowerBound]
        #expect(adoption.lowerBound < firstAttempt.lowerBound)
        #expect(firstAttemptCall.contains("configuration"))
        #expect(
            firstAttemptCall.contains(
                "audioIncidentReservation: audioIncidentReservation"))
        #expect(locked.contains("let previousTeardown = stopLocked()"))

        let internalStop = try #require(
            attempt.range(of: "stopLocked(preservingTaps: configuration.taps)"))
        let snapshot = try #require(attempt.range(of: "lastConfiguration = configuration"))
        let transfer = try #require(
            attempt.range(of: "transferTapsToActiveRouteLocked(configuration.taps)"))
        #expect(internalStop.lowerBound < snapshot.lowerBound)
        #expect(snapshot.lowerBound < transfer.lowerBound)
        #expect(!attempt.contains("let previousTeardown = stopLocked()"))

        #expect(stop.contains("tearingDown(preserving: preservingTaps)"))
        #expect(stop.contains("let uniqueTaps = transition.destroy"))
        #expect(
            stop.contains("pendingTeardownTaps.append(contentsOf: transition.next.pending)"))

        let recoveryStartCall = try #require(recovery.range(of: "try? startLocked("))
        let recoveryCallback = try #require(
            recovery.range(
                of: "onClockLockFailure?()",
                range: recoveryStartCall.upperBound..<recovery.endIndex))
        let recoveryCall =
            recovery[recoveryStartCall.lowerBound..<recoveryCallback.lowerBound]
        #expect(recoveryCall.contains("configuration"))
        #expect(
            recoveryCall.contains("activeAudioIncidentReservation?.token"))
        #expect(!recovery.contains("AudioHardwareDestroyProcessTap"))
    }
}
