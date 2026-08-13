import CoreAudio
import Testing

@testable import YunAudioHAL

@Suite("Audio hardware value policy")
struct AudioHardwareValuePolicyTests {
    @Test("the supported processing rate endpoints are exact")
    func rates() {
        #expect(AudioHardwareValuePolicy.supports(sampleRate: 8_000))
        #expect(AudioHardwareValuePolicy.supports(sampleRate: 384_000))
        for rate in [7_999, 384_001, 0, -1, Double.nan, .infinity, -.infinity] {
            #expect(!AudioHardwareValuePolicy.supports(sampleRate: rate))
        }
    }

    @Test("the slice ceiling is four thousand and ninety-six")
    func frames() {
        #expect(AudioHardwareValuePolicy.supports(framesPerSlice: 1))
        #expect(AudioHardwareValuePolicy.supports(framesPerSlice: 4_096))
        #expect(!AudioHardwareValuePolicy.supports(framesPerSlice: 0))
        #expect(!AudioHardwareValuePolicy.supports(framesPerSlice: 4_097))
        #expect(!AudioHardwareValuePolicy.supports(framesPerSlice: .max))
    }

    @Test("control waits are finite and absolutely bounded")
    func waits() {
        #expect(AudioHardwareValuePolicy.supports(controlWait: 0.001))
        #expect(AudioHardwareValuePolicy.supports(controlWait: 10))
        for timeout in [0, -1, 10.001, Double.nan, .infinity, -.infinity] {
            #expect(!AudioHardwareValuePolicy.supports(controlWait: timeout))
        }
    }

    @Test("hardware-control scalars clamp finite input and reject non-finite input")
    func controlScalars() throws {
        #expect(try AudioHardwareValuePolicy.clampedControlScalar(-1) == 0)
        #expect(try AudioHardwareValuePolicy.clampedControlScalar(0.25) == 0.25)
        #expect(try AudioHardwareValuePolicy.clampedControlScalar(2) == 1)
        for scalar in [Float.nan, .infinity, -.infinity] {
            #expect(throws: AudioHardwareValueError.self) {
                try AudioHardwareValuePolicy.clampedControlScalar(scalar)
            }
        }
    }

    @Test("hardware-control element discovery has an exact five-element bound")
    func controlElements() {
        #expect(
            AudioHardwareValuePolicy.supports(
                hardwareControlElements: [kAudioObjectPropertyElementMain, 1, 2, 3, 4]))
        for elements: [AudioObjectPropertyElement] in [
            [], [0, 0], [0, 1, 2, 3, 4, 5], [5], [.max],
        ] {
            #expect(
                !AudioHardwareValuePolicy.supports(hardwareControlElements: elements))
        }
    }

    @Test("invalid discrete HAL ranges never become offered rates")
    func discreteRanges() {
        let ranges = [
            AudioValueRange(mMinimum: .nan, mMaximum: .nan),
            AudioValueRange(mMinimum: .infinity, mMaximum: .infinity),
            AudioValueRange(mMinimum: 7_999, mMaximum: 7_999),
            AudioValueRange(mMinimum: 48_000, mMaximum: 48_000),
            AudioValueRange(mMinimum: 384_001, mMaximum: 384_001),
        ]
        #expect(AudioDevice.expand(ranges) == [48_000])
    }
}
