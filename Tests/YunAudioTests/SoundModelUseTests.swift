import Testing

@testable import YunAudioApp

/// Why Apple's on-device sound model is loaded, which is not always the switch.
@Suite("Sound model use")
struct SoundModelUseTests {

    @Test("a switch that is off does not mean a model that is not loaded")
    func levellingLoadsItRegardless() {
        // The contradiction this exists to stop showing: 「辨識聲音」 off,
        // directly above 「自動維持這個響度」 on, whose own caption says it acts
        // on the model's verdict. One of the two rows had to be wrong, and the
        // interface gave no way to tell which.
        #expect(
            SoundModelUse.of(identifying: false, levelling: true, ducking: false)
                == .forSomethingElse)
        #expect(
            SoundModelUse.of(identifying: false, levelling: false, ducking: true)
                == .forSomethingElse)
        #expect(
            SoundModelUse.of(identifying: false, levelling: false, ducking: false)
                == .notLoaded)
    }

    @Test("the switch still means what it means when it is on")
    func theSwitchWins() {
        // On is on however it got there: the readout is being kept up because
        // somebody asked for it, which is a different sentence from "something
        // else needs the model" even though both load it.
        #expect(
            SoundModelUse.of(identifying: true, levelling: false, ducking: false)
                == .forTheReadout)
        #expect(
            SoundModelUse.of(identifying: true, levelling: true, ducking: true)
                == .forTheReadout)
    }

    @Test("the badge appears whenever the model is in memory")
    func loadedCoversEveryReason() {
        // The badge shows what the model is hearing. It belongs on screen
        // exactly when there is a model to hear anything — which is the union
        // of the three reasons, not the switch.
        #expect(SoundModelUse.notLoaded.isLoaded == false)
        #expect(SoundModelUse.forTheReadout.isLoaded)
        #expect(SoundModelUse.forSomethingElse.isLoaded)
    }

    @Test("the caption says which of the two situations this is")
    @MainActor
    func captionsDiffer() {
        // A row that is loaded for somebody else's sake must not repeat the
        // sentence about loading it only when needed: that is the sentence
        // that made the pair read as a contradiction.
        #expect(SoundModelUse.forSomethingElse.caption != SoundModelUse.notLoaded.caption)
        #expect(SoundModelUse.forTheReadout.caption == SoundModelUse.notLoaded.caption)
    }
}
