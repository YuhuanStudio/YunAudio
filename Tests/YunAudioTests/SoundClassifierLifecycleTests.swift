import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

@Suite("Sound classifier lifetime")
struct SoundClassifierLifecycleTests {
    @Test("the visible analysis card does not load CoreML until its label is requested")
    func analysisCardKeepsClassificationOptional() {
        let meters = RouterModel.analysisNeeds(
            isAnalysisVisible: true,
            identifiesSounds: false,
            isSingingVisible: false,
            isAutoLevelling: false,
            isDucking: false)
        #expect(meters.contains(.loudness))
        #expect(meters.contains(.spectrum))
        #expect(meters.contains(.pitch))
        #expect(!meters.contains(.classification))

        let labelled = RouterModel.analysisNeeds(
            isAnalysisVisible: true,
            identifiesSounds: true,
            isSingingVisible: false,
            isAutoLevelling: false,
            isDucking: false)
        #expect(labelled.contains(.classification))
    }

    @Test(
        "audio features keep classification even with every window closed",
        arguments: [
            (true, false),
            (false, true),
            (true, true),
        ])
    func audioFeaturesRetainTheirGate(isAutoLevelling: Bool, isDucking: Bool) {
        let needs = RouterModel.analysisNeeds(
            isAnalysisVisible: false,
            identifiesSounds: false,
            isSingingVisible: false,
            isAutoLevelling: isAutoLevelling,
            isDucking: isDucking)
        #expect(needs.contains(.classification))
        #expect(needs.contains(.loudness) == isAutoLevelling)
    }

    @Test("two hundred meter updates construct no classifier and repeated needs construct one")
    func constructionIsBoundedByDemand() {
        var constructions = 0
        let analyser = SignalAnalyser(sampleRate: 48000) { _ in
            constructions += 1
            return nil
        }

        for _ in 0..<200 {
            analyser.require([.loudness, .spectrum, .pitch])
        }
        #expect(constructions == 0)

        for _ in 0..<200 {
            analyser.require([.loudness, .spectrum, .pitch, .classification])
        }
        #expect(constructions == 1)
    }
}
