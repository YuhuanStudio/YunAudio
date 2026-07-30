import Testing

@testable import YunAudioEngine
@testable import YunAudioOBS

@Suite("Processing latency")
struct ProcessingLatencyTests {
    @Test("output processing changes the total without changing source alignment")
    func outputDoesNotMoveAlignment() {
        let latency = ProcessingLatency(sourceFrames: 2688, outputFrames: 96)

        #expect(latency.alignmentFrames == 2688)
        #expect(latency.totalFrames == 2784)
        #expect(latency.totalMilliseconds(sampleRate: 48000) == 58)
        #expect(
            OBSSyncOffset.forProcessingLatency(
                frames: latency.totalFrames, sampleRate: 48000) == -58)
    }

    @Test("the final bank publishes its fixed delay even while bypassed")
    func finalBankDelayIsAlwaysPublished() throws {
        let bank = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        let outputFrames = ProcessingLatency.outputStageFrames(
            limiterFrames: bank.latencyFrames)
        let latency = ProcessingLatency(sourceFrames: 2688, outputFrames: outputFrames)

        #expect(outputFrames == 48)
        #expect(latency.alignmentFrames == 2688)
        #expect(latency.totalFrames == 2736)
        #expect(latency.totalMilliseconds(sampleRate: 48000) == 57)
    }

    @Test("isolation-only publishes source latency on first start")
    func isolationOnlyStart() {
        let frames = ProcessingLatency.sourceStageFrames(
            chainFrames: nil, isolationFrames: 2688)

        let latency = ProcessingLatency(sourceFrames: frames, outputFrames: 0)
        #expect(latency.sourceFrames == 2688)
        #expect(latency.alignmentFrames == 2688)
    }

    @Test("isolation-only publishes the same source latency on live update")
    func isolationOnlyLiveUpdate() {
        let before = ProcessingLatency.sourceStageFrames(
            chainFrames: nil, isolationFrames: nil)
        let after = ProcessingLatency.sourceStageFrames(
            chainFrames: nil, isolationFrames: 2688)

        #expect(before == 0)
        #expect(after == 2688)
    }

    @Test("disabling isolation removes source latency and alignment")
    func isolationDisable() {
        let frames = ProcessingLatency.sourceStageFrames(
            chainFrames: nil, isolationFrames: nil)

        let latency = ProcessingLatency(sourceFrames: frames, outputFrames: 0)
        #expect(latency.sourceFrames == 0)
        #expect(latency.alignmentFrames == 0)
        #expect(latency.totalFrames == 0)
    }

    @Test("invalid timing cannot become a negative or non-finite interface value")
    func invalidTimingIsSafe() {
        let latency = ProcessingLatency(sourceFrames: -1, outputFrames: -2)

        #expect(latency.sourceFrames == 0)
        #expect(latency.outputFrames == 0)
        #expect(latency.totalMilliseconds(sampleRate: 0) == 0)
        #expect(latency.totalMilliseconds(sampleRate: .nan) == 0)
    }
}
