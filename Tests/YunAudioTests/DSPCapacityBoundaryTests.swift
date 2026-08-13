import Foundation
import Testing

@testable import YunAudioEngine

@Suite("DSP capacity boundaries")
struct DSPCapacityBoundaryTests {
    @Test("output correction accepts exactly one maximum slice")
    func outputCorrection() {
        #expect(OutputCorrectionBank(sampleRate: 8_000, maximumFrames: 1) != nil)
        #expect(OutputCorrectionBank(sampleRate: 384_000, maximumFrames: 4_096) != nil)
        #expect(OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 0) == nil)
        #expect(OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 4_097) == nil)
        #expect(OutputCorrectionBank(sampleRate: .nan, maximumFrames: 128) == nil)
    }

    @Test("the limiter admits at most sixty-four channels in total")
    func limiterTopology() {
        #expect(
            OutputLimiterBank(
                channelCounts: Array(repeating: 1, count: 64), sampleRate: 48_000) != nil)
        #expect(
            OutputLimiterBank(
                channelCounts: Array(repeating: 1, count: 65), sampleRate: 48_000) == nil)
        #expect(OutputLimiterBank(channelCounts: [64, 1], sampleRate: 48_000) == nil)
        #expect(OutputLimiterBank(channelCounts: [2], sampleRate: .infinity) == nil)
    }

    @Test("latency planning refuses a non-representable rate")
    func voiceLatency() {
        #expect(VoicePreset.child.latencyFrames(sampleRate: 48_000) > 0)
        #expect(VoicePreset.child.latencyFrames(sampleRate: .nan) == 0)
        #expect(VoicePreset.child.latencyFrames(sampleRate: .infinity) == 0)
        #expect(VoicePreset.child.latencyFrames(sampleRate: 384_001) == 0)
    }

    @Test("key arithmetic cannot convert a hostile floating-point value")
    func keyArithmetic() throws {
        let c = try #require(KeyDetector.key(from: KeyDetector.majorProfile))
        #expect(KeyDetector.suggestedShift(songKey: c, comfortableMidi: .nan) == 0)
        #expect(KeyDetector.key(from: [.nan] + Array(repeating: 1, count: 11)) == nil)
        #expect(
            KeyDetector.chroma(
                magnitudes: [0, 1], sampleRate: 48_000, binCount: Int.max)
                == Array(repeating: 0, count: 12))
    }

    @Test("an invalid isolation probe returns before touching an Audio Unit")
    func isolationProbe() {
        let oversized = SoundIsolation.probe(
            sampleRate: 48_000, blockFrames: 4_097, iterations: 1)
        #expect(!oversized.isAvailable)
        #expect(oversized.sampleRate == 0)
        #expect(oversized.blockFrames == 0)

        let unbounded = SoundIsolation.probe(
            sampleRate: .nan, blockFrames: 128, iterations: Int.max)
        #expect(!unbounded.isAvailable)
        #expect(unbounded.sampleRate == 0)
    }

    @Test("alignment has finite numeric and work corridors")
    func alignment() {
        let valid = [
            PitchSample(time: 0, midi: 60),
            PitchSample(time: 0.02, midi: 60),
        ]
        #expect(KaraokeAlignment.align(sung: valid, reference: valid) != nil)
        #expect(KaraokeAlignment.align(sung: valid, reference: valid, bandSeconds: .nan) == nil)
        #expect(
            KaraokeAlignment.align(
                sung: [
                    PitchSample(time: 0, midi: 60),
                    PitchSample(time: .leastNonzeroMagnitude, midi: 60),
                ], reference: valid) == nil)
        #expect(
            KaraokeAlignment.align(
                sung: valid,
                reference: [PitchSample(time: .infinity, midi: 60)]) == nil)
        #expect(KaraokeAlignment.maximumCorridorSamples == 4_096)
        #expect(KaraokeAlignment.maximumAlignmentCells == 20_000_000)
    }

    @Test("clock anchors cross the property list without rounding")
    func clockAnchor() throws {
        #expect(
            ClockAnchor(
                sampleTime: 0, hostTime: (1 << 53) + 1, sampleRate: 384_000
            ).isValid)
        #expect(
            ClockAnchor(
                sampleTime: 0, hostTime: UInt64(Int64.max), sampleRate: 48_000
            ).isValid)
        #expect(
            !ClockAnchor(
                sampleTime: 0, hostTime: UInt64(Int64.max) + 1, sampleRate: 48_000
            ).isValid)

        let encoded = try #require(
            ClockAnchorPublisher.hostTimePropertyNumber(UInt64(Int64.max)))
        var decoded: Int64 = 0
        #expect(CFNumberGetType(encoded) == .sInt64Type)
        #expect(CFNumberGetValue(encoded, .sInt64Type, &decoded))
        #expect(decoded == Int64.max)
        #expect(
            !ClockAnchor(
                sampleTime: .nan, hostTime: 1, sampleRate: 48_000
            ).isValid)
        #expect(
            !ClockAnchor(
                sampleTime: 0, hostTime: 1, sampleRate: .infinity
            ).isValid)
    }
}
