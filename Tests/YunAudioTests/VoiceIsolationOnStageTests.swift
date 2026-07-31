import Foundation
import Testing

@testable import YunAudioApp

/// Voice isolation on a stage.
///
/// Apple's model keeps one person speaking and removes everything else. On a
/// call that is the whole point; on a KTV stage it treats the backing track and
/// the singing as the noise it exists to delete, and adds 56 ms. Two presets —
/// 「語音通話」and 「吵雜環境」— switch it on, and somebody who set one up months
/// ago has no reason to connect the two.
@Suite("voice isolation while singing")
@MainActor
struct VoiceIsolationOnStageTests {

    @Test("the presets that turn it on are the ones about a phone call")
    func whichPresetsEnableIt() {
        // Named rather than counted: if a third preset ever enables it, this
        // says so and somebody decides on purpose.
        let enabling = RoutePreset.builtIn.filter { $0.voiceIsolationEnabled }.map(\.name)
        #expect(enabling.count == 2, "enabling presets: \(enabling)")
    }

    @Test("nothing is said when the stage is closed")
    func silentOffStage() {
        let model = RouterModel()
        model.isSingingVisible = false
        model.voiceIsolationEnabled = true
        model.voiceIsolationMix = 100
        #expect(!model.voiceIsolationWillHurtSinging)
    }

    @Test("nor when it is off")
    func silentWhenOff() {
        let model = RouterModel()
        model.isSingingVisible = true
        model.voiceIsolationEnabled = false
        #expect(!model.voiceIsolationWillHurtSinging)
    }

    @Test("nor at a strength somebody may have chosen on purpose")
    func silentWhenGentle() {
        // Warning about 5% would train people to ignore the line that matters
        // at 100%.
        let model = RouterModel()
        model.isSingingVisible = true
        model.voiceIsolationEnabled = true
        model.voiceIsolationMix = 10
        #expect(!model.voiceIsolationWillHurtSinging)
    }

    @Test("but it is said when the song is about to be deleted")
    func warnsWhenItMatters() {
        let model = RouterModel()
        model.isSingingVisible = true
        model.voiceIsolationEnabled = true
        model.voiceIsolationMix = 100
        #expect(model.voiceIsolationWillHurtSinging)
    }
}
