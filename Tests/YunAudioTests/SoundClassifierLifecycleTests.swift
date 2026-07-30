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

    @Test("an idle analyser retains no drain buffer")
    func idleDrainStorage() {
        let analyser = SignalAnalyser(sampleRate: 48_000) { _ in nil }

        #expect(analyser.workingBufferBytes == 0)
        #expect(analyser.loudnessStorageBytes == 0)
        // A direct caller is not required to reproduce RouterModel's isIdle
        // guard. This used to force-unwrap an empty Array's base address.
        analyser.drain(from: RoutingEngine())
        #expect(analyser.workingBufferBytes == 0)
        analyser.require(.loudness)
        #expect(SignalAnalyser.workingBufferFrames == 24_576)
        #expect(analyser.workingBufferBytes == 98_304)
        #expect(analyser.loudnessStorageBytes == 3_033_856)
        analyser.require([])
        #expect(analyser.workingBufferBytes == 0)
        // Integrated loudness is state for this route, and closing a view must
        // not rewrite its meaning.
        #expect(analyser.loudnessStorageBytes == 3_033_856)
    }

    @Test("ducking does not allocate a loudness history")
    func classifierOnlyStorage() {
        let analyser = SignalAnalyser(sampleRate: 48_000) { _ in nil }
        analyser.require(.classification)

        #expect(analyser.workingBufferBytes == 98_304)
        #expect(analyser.loudnessStorageBytes == 0)

        analyser.addForTesting([Float](repeating: 0, count: 48_000 * 10))
        #expect(analyser.reading().duration == 0)

        analyser.require([.classification, .loudness])
        analyser.addForTesting([Float](repeating: 0, count: 480))
        #expect(analyser.reading().duration == 0.01)
    }

    @Test("meter-only readings share one zero-spectrum allocation")
    func silentSpectrumIsShared() {
        let analyser = SignalAnalyser(sampleRate: 48_000) { _ in nil }
        analyser.require(.loudness)

        let addresses = (0..<1_000).map { _ in
            analyser.reading().bands.withUnsafeBufferPointer {
                $0.baseAddress.map { UInt(bitPattern: $0) } ?? 0
            }
        }

        #expect(Set(addresses).count == 1)
        #expect(addresses.first != 0)
        #expect(SignalAnalyser.silentBands.count == SpectrumAnalyser.bandCount)
    }
}
