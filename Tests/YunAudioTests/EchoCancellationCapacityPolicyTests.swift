import AudioToolbox
import Testing

@testable import YunAudioEngine

@Suite("Echo-cancellation allocation bounds")
struct EchoCancellationCapacityPolicyTests {
    @Test("the shared sample-rate boundary is inclusive and finite")
    func sampleRateBoundsAreExact() {
        #expect(EchoCancellationCapacityPolicy.isValidSampleRate(8_000))
        #expect(EchoCancellationCapacityPolicy.isValidSampleRate(384_000))

        let rejected: [Double] = [
            .nan, .infinity, -.infinity, -1, 0, 7_999.999,
            384_000.001, .greatestFiniteMagnitude,
        ]
        for value in rejected {
            #expect(!EchoCancellationCapacityPolicy.isValidSampleRate(value))
        }
    }

    @Test("HAL slices produce one fully checked capture allocation")
    func captureAllocationBoundsAreExact() {
        #expect(
            EchoCancellationCapacityPolicy.captureAllocation(
                requestedSliceFrames: 1, deviceSliceFrames: 0)
                == EchoCancellationCapacityPolicy.CaptureAllocation(
                    bufferFrames: 8_192,
                    bufferFrameCount: 8_192,
                    bufferBytes: 32_768,
                    unitSliceFrames: 1))
        #expect(
            EchoCancellationCapacityPolicy.captureAllocation(
                requestedSliceFrames: 512, deviceSliceFrames: 1_394)
                == EchoCancellationCapacityPolicy.CaptureAllocation(
                    bufferFrames: 8_192,
                    bufferFrameCount: 8_192,
                    bufferBytes: 32_768,
                    unitSliceFrames: 1_394))
        #expect(
            EchoCancellationCapacityPolicy.captureAllocation(
                requestedSliceFrames: 4_096, deviceSliceFrames: 4_096)
                == EchoCancellationCapacityPolicy.CaptureAllocation(
                    bufferFrames: 16_384,
                    bufferFrameCount: 16_384,
                    bufferBytes: 65_536,
                    unitSliceFrames: 4_096))

        for requested in [-1, 0, 4_097, Int.max] {
            #expect(
                EchoCancellationCapacityPolicy.captureAllocation(
                    requestedSliceFrames: requested,
                    deviceSliceFrames: 512) == nil)
        }
        #expect(
            EchoCancellationCapacityPolicy.captureAllocation(
                requestedSliceFrames: 512,
                deviceSliceFrames: UInt32.max) == nil)
    }

    @Test("sample and byte products reject overflow and UInt32 truncation")
    func productsAreCheckedBeforeConversion() {
        #expect(
            EchoCancellationCapacityPolicy.checkedUInt32Product(4, 64) == 256)
        #expect(
            EchoCancellationCapacityPolicy.checkedUInt32Product(
                UInt32.max, 4) == nil)
        #expect(
            EchoCancellationCapacityPolicy.checkedByteCount(
                frames: 768_000) == 3_072_000)
        #expect(
            EchoCancellationCapacityPolicy.checkedByteCount(
                frames: Int(UInt32.max)) == nil)
        #expect(
            EchoCancellationCapacityPolicy.checkedByteCount(
                frames: Int.max, channels: 4) == nil)
        #expect(
            EchoCancellationCapacityPolicy.checkedByteCount(
                frames: -1) == nil)
    }

    @Test("ring duration has an exact two-second semantic ceiling")
    func ringBoundsAreExact() {
        #expect(
            EchoCancellationCapacityPolicy.ringFrameCapacity(
                sampleRate: 8_000, seconds: 0.25) == 2_000)
        #expect(
            EchoCancellationCapacityPolicy.ringFrameCapacity(
                sampleRate: 44_100, seconds: 0.25) == 11_025)
        #expect(
            EchoCancellationCapacityPolicy.ringFrameCapacity(
                sampleRate: 384_000, seconds: 2) == 768_000)
        #expect(
            EchoCancellationCapacityPolicy.ringStorageFrameCapacity(
                requestedFrames: 1) == 1_024)
        #expect(
            EchoCancellationCapacityPolicy.ringStorageFrameCapacity(
                requestedFrames: 1_024) == 1_024)
        #expect(
            EchoCancellationCapacityPolicy.ringStorageFrameCapacity(
                requestedFrames: 1_025) == 2_048)
        #expect(
            EchoCancellationCapacityPolicy.ringStorageFrameCapacity(
                requestedFrames: 768_000) == 1_048_576)
        #expect(
            EchoCancellationCapacityPolicy.ringStorageFrameCapacity(
                requestedFrames: UInt32.max) == nil)

        let rejectedSeconds: [Double] = [
            .nan, .infinity, -.infinity, -1, 0, 0.000_01, 2.000_001,
            .greatestFiniteMagnitude,
        ]
        for seconds in rejectedSeconds {
            #expect(
                EchoCancellationCapacityPolicy.ringFrameCapacity(
                    sampleRate: 8_000, seconds: seconds) == nil)
        }
        #expect(
            EchoCancellationCapacityPolicy.ringFrameCapacity(
                sampleRate: .greatestFiniteMagnitude,
                seconds: 0.25) == nil)
    }

    @Test("ring and scratch byte ceilings are fixed before allocation")
    func ringAllocationBoundsAreExact() {
        #expect(
            EchoCancellationCapacityPolicy.ringAllocation(
                sampleRate: 384_000,
                seconds: 2,
                requestedSliceFrames: 4_096,
                sourceChannels: 64)
                == EchoCancellationCapacityPolicy.RingAllocation(
                    ringFrames: 768_000,
                    ringStorageFrames: 1_048_576,
                    ringBytes: 4_194_304,
                    scratchFrames: 4_096,
                    scratchFrameCount: 4_096,
                    scratchBytes: 16_384))
        #expect(
            EchoCancellationCapacityPolicy.ringAllocation(
                sampleRate: 48_000,
                seconds: 0.25,
                requestedSliceFrames: 4_097) == nil)
        #expect(
            EchoCancellationCapacityPolicy.ringAllocation(
                sampleRate: 48_000,
                seconds: 0.25,
                requestedSliceFrames: 512,
                sourceChannels: 65) == nil)
        #expect(
            EchoCancellationCapacityPolicy.ringAllocation(
                sampleRate: 48_000,
                seconds: 0.25,
                requestedSliceFrames: 512,
                sourceChannels: UInt32.max) == nil)
    }

    @Test("malformed ASBD rates, channels and packet sizes fail closed")
    func malformedTapFormatsAreRejected() {
        #expect(FarEndCapture.supportsTapFormat(tapFormat(rate: 8_000, channels: 1)))
        #expect(
            FarEndCapture.supportsTapFormat(
                tapFormat(rate: 384_000, channels: 64)))

        for rate in [
            Double.nan, .infinity, -.infinity, -1, 0, 7_999, 384_001,
            .greatestFiniteMagnitude,
        ] {
            #expect(
                !FarEndCapture.supportsTapFormat(
                    tapFormat(rate: rate, channels: 2)))
        }
        for channels in [UInt32(0), 65, UInt32.max] {
            #expect(
                !FarEndCapture.supportsTapFormat(
                    tapFormat(rate: 48_000, channels: channels)))
        }

        var oversizedFrame = tapFormat(rate: 48_000, channels: UInt32.max)
        oversizedFrame.mBytesPerFrame = UInt32.max
        oversizedFrame.mBytesPerPacket = UInt32.max
        #expect(!FarEndCapture.supportsTapFormat(oversizedFrame))

        var packetMismatch = tapFormat(rate: 48_000, channels: 2)
        packetMismatch.mBytesPerPacket = UInt32.max
        #expect(!FarEndCapture.supportsTapFormat(packetMismatch))

        var byteOverflow = tapFormat(rate: 48_000, channels: 2)
        byteOverflow.mBytesPerFrame = UInt32.max
        byteOverflow.mBytesPerPacket = UInt32.max
        #expect(!FarEndCapture.supportsTapFormat(byteOverflow))

        var multipleFrames = tapFormat(rate: 48_000, channels: 2)
        multipleFrames.mFramesPerPacket = UInt32.max
        #expect(!FarEndCapture.supportsTapFormat(multipleFrames))

        var reserved = tapFormat(rate: 48_000, channels: 2)
        reserved.mReserved = UInt32.max
        #expect(!FarEndCapture.supportsTapFormat(reserved))
    }

    @Test("unsafe error details preserve malformed doubles without conversion")
    func malformedRateDetailsDoNotConvertToInt() {
        let clockDetail = EchoCancellationSetupError.captureClockDiffersFromRouter(
            captureRate: .nan, routerRate: .infinity
        ).detail
        #expect(clockDetail.lowercased().contains("nan"))
        #expect(clockDetail.lowercased().contains("inf"))

        let microphoneDetail =
            EchoCancellationSetupError.microphoneCannotPresentRouterRate(
                microphoneRates: [.nan, .greatestFiniteMagnitude],
                routerRate: -.infinity
            ).detail
        #expect(microphoneDetail.lowercased().contains("inf"))
    }

    private func tapFormat(
        rate: Double,
        channels: UInt32,
        nonInterleaved: Bool = false
    ) -> AudioStreamBasicDescription {
        let flags =
            kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | (nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0)
        let bytes =
            EchoCancellationCapacityPolicy.bytesPerFrame(
                channels: channels, nonInterleaved: nonInterleaved) ?? 0
        return AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }
}
