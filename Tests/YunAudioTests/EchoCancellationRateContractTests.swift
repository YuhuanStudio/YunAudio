import Testing

@testable import YunAudioEngine

@Suite("Echo-cancellation sample-rate contract")
struct EchoCancellationRateContractTests {
    @Test(
        "matching tap, canceller and router clocks carry frames one for one",
        arguments: [44_100.0, 48_000.0, 96_000.0]
    )
    func matchingClocksAreAccepted(rate: Double) {
        let contract = EchoCancellationRateContract(
            farEndRate: rate, captureRate: rate, routerRate: rate)

        #expect(contract.canCarryFarEndReference)
        #expect(contract.canCarryCancelledAudio)
        #expect(
            EchoCancellationRateContract.driftFramesPerSecond(
                producerRate: rate, consumerRate: rate) == 0)
    }

    @Test("44.1 kHz tap frames are not presented to a 48 kHz canceller")
    func rejectsMismatchedFarEndClock() {
        let contract = EchoCancellationRateContract(
            farEndRate: 44_100, captureRate: 48_000, routerRate: 48_000)

        #expect(!contract.canCarryFarEndReference)
        #expect(contract.canCarryCancelledAudio)
        #expect(
            EchoCancellationRateContract.driftFramesPerSecond(
                producerRate: 44_100, consumerRate: 48_000) == -3_900)
        #expect(
            EchoCancellationRateContract.secondsToConsumeSlack(
                capacityFrames: 11_025,
                producerRate: 44_100,
                consumerRate: 48_000) == 11_025.0 / 3_900.0)
    }

    @Test("96 kHz tap frames would fill a 48 kHz ring in half a second")
    func quantifiesFastProducerDrift() {
        let contract = EchoCancellationRateContract(
            farEndRate: 96_000, captureRate: 48_000, routerRate: 48_000)

        #expect(!contract.canCarryFarEndReference)
        #expect(
            EchoCancellationRateContract.driftFramesPerSecond(
                producerRate: 96_000, consumerRate: 48_000) == 48_000)
        #expect(
            EchoCancellationRateContract.secondsToConsumeSlack(
                capacityFrames: 24_000,
                producerRate: 96_000,
                consumerRate: 48_000) == 0.5)
    }

    @Test("48 kHz cancelled frames cannot feed a 96 kHz router one for one")
    func rejectsMismatchedRouterClock() {
        let contract = EchoCancellationRateContract(
            farEndRate: 48_000, captureRate: 48_000, routerRate: 96_000)

        #expect(contract.farEndMatchesCapture)
        #expect(!contract.canCarryCancelledAudio)
        #expect(!contract.canCarryFarEndReference)
        #expect(
            EchoCancellationRateContract.driftFramesPerSecond(
                producerRate: 48_000, consumerRate: 96_000) == -48_000)
    }

    @Test(
        "the dedicated canceller honours the router's exact shared clock",
        arguments: [44_100.0, 48_000.0, 96_000.0]
    )
    func dedicatedCaptureHonoursRequiredRate(rate: Double) {
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [44_100, 48_000, 96_000],
                speakerRates: [44_100, 48_000, 96_000],
                requiredRate: rate) == rate)
    }

    @Test("a required rate unsupported by either endpoint is rejected")
    func rejectsUnsupportedRequiredRate() {
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [48_000, 96_000],
                speakerRates: [44_100, 48_000],
                requiredRate: 96_000) == nil)
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [44_100],
                speakerRates: [48_000],
                requiredRate: 48_000) == nil)
    }

    @Test("standalone voice capture still prefers 48 kHz")
    func standaloneCapturePrefersVoiceRate() {
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [44_100, 48_000, 96_000],
                speakerRates: [44_100, 48_000, 96_000],
                requiredRate: nil) == 48_000)
    }
}
