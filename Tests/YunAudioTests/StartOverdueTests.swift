import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

/// What the interface says when Core Audio stops answering.
///
/// Reproduced on 2026-08-25: `AudioDeviceCreateIOProcID` sent a mach message to
/// coreaudiod and never returned — in this application, in a fresh launch of
/// it, and in an unrelated command-line tool. Read-only property calls kept
/// working the whole time, so the device list looked perfectly healthy while
/// nothing could be opened.
///
/// None of that can be fixed from here. What these fix is the reporting, which
/// was a spinner with no end and a message reading "new audio ownership refused
/// while 2 cleanup owner(s) remain".
@MainActor
@Suite("When Core Audio stops answering")
struct StartOverdueTests {

    /// Twelve seconds is not a slow start. A start is under two seconds on a
    /// wired path and a few on Bluetooth, so the number has to be far enough
    /// above both that it can only mean a call that is not coming back.
    @Test("the threshold is well clear of a slow start")
    func thresholdIsClearOfASlowStart() {
        #expect(RouterModel.startIsOverdueAfter >= 10)
    }

    /// Nothing is said while nothing is being waited for. A notice that appears
    /// on an idle application would be read as a fault in the application.
    @Test("nothing is said when no start is outstanding")
    func silentWhenIdle() {
        let model = RouterModel()
        #expect(!model.isBusy)
        #expect(model.startOverdueWarning == nil)
    }

    /// A fresh process can build graphs, so neither relaunch sentence applies.
    @Test("a healthy process says nothing about relaunching")
    func healthyProcessSaysNothing() {
        let model = RouterModel()
        #expect(!model.mustBeRelaunched)
        #expect(model.relaunchWarning == nil)
    }

    /// The two quarantines are different facts with different costs, and the
    /// engine has to be able to say which — one loses echo cancellation, the
    /// other loses every route.
    @Test("the two quarantines are read separately")
    func quarantinesAreReadSeparately() {
        let engine = RoutingEngine()
        #expect(!engine.audioUnitConstructionIsQuarantined)
        #expect(!engine.echoCancellationConstructionIsQuarantined)
    }

    /// The echo canceller's sentence is only for somebody who asked for it.
    /// Telling a person a feature they never switched on is unavailable is
    /// noise, and noise in this position is what teaches people to ignore the
    /// position.
    @Test("the echo sentence needs the echo canceller to have been asked for")
    func echoSentenceNeedsTheSwitch() {
        let model = RouterModel()
        model.cancelsEcho = false
        #expect(model.relaunchWarning == nil)
    }
}

@MainActor
@Suite("Relaunching itself")
struct RelaunchApplicationTests {

    private final class Calls {
        var quits = 0
    }

    /// The replacement is started first and the quit only follows a success.
    ///
    /// A copy that failed to relaunch and then quit anyway leaves somebody with
    /// nothing, which is worse than the broken copy they had — that one at
    /// least still shows the notice explaining itself.
    @Test("a failed open does not quit")
    func failedOpenDoesNotQuit() {
        let calls = Calls()
        RelaunchApplication.now(
            bundleURL: URL(fileURLWithPath: "/nowhere"),
            open: { _, completion in completion(false) },
            quit: { calls.quits += 1 })
        #expect(calls.quits == 0)
    }

    @Test("a successful open quits exactly once")
    func successfulOpenQuitsOnce() {
        let calls = Calls()
        RelaunchApplication.now(
            bundleURL: URL(fileURLWithPath: "/nowhere"),
            open: { _, completion in completion(true) },
            quit: { calls.quits += 1 })
        #expect(calls.quits == 1)
    }

    /// Without a new instance being asked for, this is a no-op: the copy asking
    /// is still running, and `NSWorkspace` would activate it rather than start
    /// another.
    @Test("a new instance is asked for explicitly")
    func asksForANewInstance() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RelaunchApplication.swift", encoding: .utf8)
        #expect(source.contains("createsNewApplicationInstance = true"))
    }
}

@MainActor
@Suite("The overdue notice says what the server answered")
struct OverdueDiagnosisTests {

    /// Two sentences, and the difference between them is what somebody does
    /// next. "Several seconds and no answer" describes waiting; the other one
    /// says waiting is not going to work and gives the command that is.
    @Test("the wedged sentence and the generic one are different")
    func wedgedSentenceIsDistinct() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        let start = try #require(source.range(of: "var startOverdueWarning: String? {"))
        let body = source[start.upperBound...].prefix(1400)
        #expect(body.contains("audioServerVerdict == .notOpeningDevices"))
        // Named, because that is the only thing that ends this state — measured
        // to survive eight minutes with nothing running.
        #expect(body.contains("sudo killall coreaudiod"))
    }

    /// The probe is only run once a start has actually gone overdue. It costs
    /// three seconds and leaks a thread when the answer is bad, which is not a
    /// price to pay on a start that is merely slow.
    @Test("the server is asked only after the watchdog fires")
    func serverIsAskedOnlyWhenOverdue() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        let start = try #require(source.range(of: "private func armStartWatchdog()"))
        let body = source[start.upperBound...].prefix(1600)
        let overdue = try #require(body.range(of: "startIsOverdue = true"))
        let asked = try #require(body.range(of: "AudioServerHealth.check()"))
        #expect(overdue.lowerBound < asked.lowerBound)
    }

    @Test("nothing has been asked before a start is outstanding")
    func nothingAskedYet() {
        let model = RouterModel()
        #expect(model.audioServerVerdict == nil)
    }
}
