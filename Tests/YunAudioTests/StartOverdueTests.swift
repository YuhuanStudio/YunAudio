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
