import Foundation
import Testing

@testable import YunAudioHAL

/// Telling a wedged audio server apart from a busy one.
///
/// The distinction is the whole value: "Core Audio is not answering" invites
/// waiting, and waiting never ends a wedge. "Core Audio answers questions and
/// will not open a device" is a different sentence with a different action.
///
/// The probe is injectable because the real one cannot be made to fail on
/// demand — and because it leaks a thread when it does, which is not something
/// to do 2000 times a run.
@Suite("Is the audio server still opening devices", .serialized)
struct AudioServerHealthTests {

    /// A call that never returns is the case this exists for, and the only way
    /// to learn that is to stop waiting.
    @Test("a read that answers and an open that does not is a wedge")
    func answeringButNotOpeningIsAWedge() {
        let never = DispatchSemaphore(value: 0)
        let verdict = AudioServerHealth.probe(
            budget: 0.2,
            readProperty: { true },
            openAndClose: {
                never.wait()
                return true
            })
        #expect(verdict == .notOpeningDevices)
        never.signal()
    }

    /// A machine that cannot answer a property read either is not diagnosable
    /// from here, and saying so beats choosing one of the two.
    @Test("a read that does not answer is reported as itself")
    func silentServerIsReportedAsItself() {
        let never = DispatchSemaphore(value: 0)
        let verdict = AudioServerHealth.probe(
            budget: 0.2,
            readProperty: {
                never.wait()
                return true
            },
            openAndClose: { true })
        #expect(verdict == .notAnswering)
        never.signal()
    }

    @Test("a server that opens a device is healthy")
    func openingIsHealthy() {
        let verdict = AudioServerHealth.probe(
            budget: TestGate.deadlockSeconds,
            readProperty: { true }, openAndClose: { true })
        #expect(verdict == .healthy)
    }

    /// The budget is a claim about a healthy machine, not a guess: opening and
    /// closing an IOProc is milliseconds, so three seconds cannot be a slow
    /// open — only one that is not coming back.
    @Test("the budget is far above a real open")
    func budgetIsFarAboveARealOpen() {
        #expect(AudioServerHealth.budget >= 2)
    }
}

/// The probe has to ask the question a route asks.
///
/// Three versions of this reported a healthy machine while every real route was
/// failing on it: a property read, an IOProc on the default output, and an
/// IOProc on every existing device. Each was true and none was the question.
/// What a route does is build a private aggregate with an input and an output
/// in it, correct drift between them, open it, and take it down — and it was
/// the taking down that would not come back.
@Suite("The health probe is shaped like a route")
struct HealthProbeShapeTests {

    private static func source() throws -> String {
        try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioHAL/AudioServerHealth.swift", encoding: .utf8)
    }

    /// Two members, because a one-member aggregate built, opened and tore down
    /// in a second on a machine where routes were timing out after three
    /// minutes.
    @Test("the probe aggregate has an input and an output")
    func probeHasTwoMembers() throws {
        let source = try Self.source()
        #expect(source.contains("driftCompensation: false"))
        #expect(source.contains("driftCompensation: true"))
        #expect(source.contains("$0.hasInput"))
    }

    /// And it waits for the teardown. Creating was always fast; destroying was
    /// the call that hung, and a probe that skips it cannot see the fault.
    @Test("the probe waits for the aggregate to be destroyed")
    func probeWaitsForTeardown() throws {
        let source = try Self.source()
        #expect(source.contains("destroyAndWait"))
        #expect(source.contains("== .destroyed"))
    }
}
