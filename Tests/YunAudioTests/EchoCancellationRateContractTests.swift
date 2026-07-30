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

    @Test("a required rate the microphone cannot produce is rejected")
    func rejectsUnsupportedRequiredRate() {
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [44_100],
                speakerRates: [48_000],
                requiredRate: 48_000) == nil)
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [],
                speakerRates: [48_000],
                requiredRate: 48_000) == nil)
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [48_000],
                speakerRates: [48_000],
                requiredRate: 0) == nil)
    }

    /// The pair that killed this feature on the machine it is developed on.
    ///
    /// A Seiren V3 Pro offers 48 k and 96 k; a Razer Barracuda over Bluetooth
    /// negotiates HFP and offers 16 k. Their intersection is empty, and the
    /// canceller used to refuse the pair and vanish without a word — for a
    /// router running at 48 kHz, which is a rate the microphone presents
    /// natively. The speaker is a drift-compensated follower and the HAL
    /// converts for it, exactly as the route already does for a Bluetooth
    /// destination.
    @Test("a 16 kHz Bluetooth speaker does not veto a 48 kHz microphone")
    func bluetoothSpeakerDoesNotVetoTheMicrophone() {
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [48_000, 96_000],
                speakerRates: [16_000],
                requiredRate: 48_000) == 48_000)
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [48_000, 96_000],
                speakerRates: [44_100],
                requiredRate: 96_000) == 96_000)
        // A speaker whose capabilities were never read is the same case: an
        // empty list is "not asked", not "supports nothing", and it must not
        // decide anything about the microphone.
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [48_000, 96_000],
                speakerRates: [],
                requiredRate: 48_000) == 48_000)
    }

    /// Without a consumer fixing the clock there is no reason to make either
    /// device convert, so the shared-rate rule still stands there.
    @Test("standalone capture still refuses a pair with no rate in common")
    func standaloneCaptureStillNeedsASharedRate() {
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [48_000, 96_000],
                speakerRates: [16_000],
                requiredRate: nil) == nil)
        #expect(
            EchoCancellingCapture.sampleRate(
                microphoneRates: [44_100, 96_000],
                speakerRates: [44_100, 96_000],
                requiredRate: nil) == 96_000)
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
