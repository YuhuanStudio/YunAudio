import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

/// The blast radius of a construction that never returns.
///
/// Reproduced on 2026-08-25: building the voice-processing unit reached
/// `AudioDeviceCreateIOProcID`, sent a mach message to coreaudiod and did not
/// come back. A synchronous vendor call cannot be cancelled, so the lane keeps
/// the wedged worker and quarantines itself for the life of the process — which
/// is right. What was wrong is that it was the same lane every route needs, so
/// one lost feature took every route with it and the application went on
/// reporting success.
@Suite("A wedged echo canceller is not a dead application")
struct EchoLaneContainmentTests {

    /// The two lanes are genuinely different objects. A property that reads as
    /// separation and is really `shared` under another name would pass every
    /// behavioural check here by accident.
    @Test("the echo canceller has a lane of its own")
    func lanesAreDistinct() {
        #expect(
            BoundedAudioUnitConstructionLane.echoCancellation
                !== BoundedAudioUnitConstructionLane.shared)
    }

    /// The claim, stated as itself: a lane that has quarantined itself refuses
    /// for ever, and the other one does not notice.
    @Test("quarantining one lane leaves the other admitting")
    func quarantineDoesNotSpread() {
        // Their own quarantine, not the process-wide one.
        //
        // The lane's default is `ProcessLifetimeAudioQuarantine.shared`, and
        // this test deliberately wedges a constructor — so with the default it
        // would leave a retained entry behind, and every `EffectChain` built
        // anywhere in the process afterwards would be refused admission. It
        // did: three unrelated formant tests started failing four runs in five,
        // reporting a staging-path fault that had never happened.
        let echo = BoundedAudioUnitConstructionLane(
            quarantine: ProcessLifetimeAudioQuarantine(),
            label: "yunaudio.test.echo-containment.echo")
        let graph = BoundedAudioUnitConstructionLane(
            quarantine: ProcessLifetimeAudioQuarantine(),
            label: "yunaudio.test.echo-containment.graph")
        let released = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)

        // A constructor that does not return, which is the case being modelled.
        DispatchQueue.global().async {
            let result: AudioUnitLaneResult<Int> = echo.perform(timeout: 0.25) { _ in
                entered.signal()
                released.wait()
                return 1
            }
            _ = result
        }
        #expect(entered.wait(timeout: .now() + TestGate.deadlock) == .success)

        // The timeout has to be observed rather than slept through, since the
        // worker is still inside the operation and always will be.
        var admitting = true
        for _ in 0..<TestGate.polls where admitting {
            admitting = echo.admitsConstruction
            if admitting { Thread.sleep(forTimeInterval: 0.001) }
        }
        #expect(!echo.admitsConstruction, "the wedged lane never quarantined")

        // The one the route needs is untouched, which is the whole change.
        #expect(graph.admitsConstruction)
        let built: AudioUnitLaneResult<Int> = graph.perform(timeout: TestGate.deadlockSeconds) {
            _ in 7
        }
        if case .completed(let value) = built {
            #expect(value == 7)
        } else {
            Issue.record("the untouched lane refused a construction: \(built)")
        }
        released.signal()
    }

    /// And the route's own admission check must not consult the echo lane —
    /// doing so would put the failure straight back where it was.
    @Test("the route's admission does not ask the echo lane")
    func routeAdmissionIgnoresTheEchoLane() throws {
        let source = try String(
            contentsOfFile: GraphLockDisciplineTests.enginePath, encoding: .utf8)
        let start = try #require(source.range(of: "func requireAudioUnitGraphAdmission()"))
        let body = source[start.upperBound...].prefix(400)
        #expect(body.contains("BoundedAudioUnitConstructionLane.shared.admitsConstruction"))
        #expect(!body.contains("echoCancellation.admitsConstruction"))
    }
}

/// Not adding a second wedged thread to a machine already in that state.
@Suite("A known-bad server is not asked again")
struct EchoSkipsAKnownBadServerTests {

    /// The check is a *read* of what this process already established, not a
    /// probe. Probing costs three seconds and leaks a thread of its own when
    /// the answer is bad, and the middle of a route is not the place for that.
    @Test("the route reads the last verdict rather than taking a new one")
    func readsRatherThanProbes() throws {
        let source = try String(
            contentsOfFile: GraphLockDisciplineTests.enginePath, encoding: .utf8)
        let start = try #require(source.range(of: "var bridge: EchoCancellationBridge?"))
        let end = try #require(
            source.range(
                of: "let cancelsEcho = bridge != nil",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        #expect(body.contains("AudioServerHealth.lastVerdict == .notOpeningDevices"))
        #expect(!body.contains("AudioServerHealth.check("))
        #expect(!body.contains("AudioServerHealth.probe"))
    }

    /// And the skip has to come before the construction, which is the only
    /// position in which it prevents anything.
    @Test("the skip precedes the constructor")
    func skipPrecedesTheConstructor() throws {
        let source = try String(
            contentsOfFile: GraphLockDisciplineTests.enginePath, encoding: .utf8)
        let start = try #require(source.range(of: "var bridge: EchoCancellationBridge?"))
        let body = source[start.upperBound...].prefix(4000)
        let skip = try #require(body.range(of: "AudioServerHealth.lastVerdict"))
        let build = try #require(body.range(of: "try EchoCancellationBridge("))
        #expect(skip.lowerBound < build.lowerBound)
    }
}
