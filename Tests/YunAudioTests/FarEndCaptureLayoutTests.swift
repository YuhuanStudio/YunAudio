import CoreAudio
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Far-end buffer layout", .serialized)
struct FarEndCaptureLayoutTests {
    @Test(
        "packed float32 is accepted in interleaved and non-interleaved layouts",
        arguments: [false, true]
    )
    func acceptsSupportedTapFormats(nonInterleaved: Bool) {
        #expect(
            FarEndCapture.supportsTapFormat(
                tapFormat(nonInterleaved: nonInterleaved)))
    }

    @Test("integer and padded tap formats are rejected before the callback")
    func rejectsFormatsTheCallbackCannotInterpret() {
        var integer = tapFormat(nonInterleaved: false)
        integer.mFormatFlags =
            kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        #expect(!FarEndCapture.supportsTapFormat(integer))

        var padded = tapFormat(nonInterleaved: false)
        padded.mBytesPerFrame += 4
        #expect(!FarEndCapture.supportsTapFormat(padded))

        var wrongEndian = tapFormat(nonInterleaved: false)
        wrongEndian.mFormatFlags |= kAudioFormatFlagIsBigEndian
        #expect(!FarEndCapture.supportsTapFormat(wrongEndian))
    }

    @Test("one interleaved stereo buffer uses its channel count as stride")
    func downmixesInterleavedStereo() {
        let input = BufferListFixture([
            .init(channels: 2, samples: [1, 3, 2, 4])
        ])
        var output = [Float](repeating: 0, count: 2)

        let frames = output.withUnsafeMutableBufferPointer {
            FarEndCapture.downmix(
                input.list, into: $0.baseAddress!, capacity: $0.count)
        }

        #expect(frames == 2)
        #expect(output == [2, 3])
    }

    @Test("non-interleaved channels in separate buffers are both included")
    func downmixesNonInterleavedStereo() {
        let input = BufferListFixture([
            .init(channels: 1, samples: [1, 2]),
            .init(channels: 1, samples: [3, 4]),
        ])
        var output = [Float](repeating: 0, count: 2)

        let frames = output.withUnsafeMutableBufferPointer {
            FarEndCapture.downmix(
                input.list, into: $0.baseAddress!, capacity: $0.count)
        }

        #expect(frames == 2)
        #expect(output == [2, 3])
    }

    @Test("several interleaved buffer groups use their own strides")
    func downmixesMultipleBufferGroups() {
        let input = BufferListFixture([
            .init(channels: 2, samples: [1, 3, 2, 4]),
            .init(channels: 1, samples: [5, 8]),
        ])
        var output = [Float](repeating: 0, count: 2)

        let frames = output.withUnsafeMutableBufferPointer {
            FarEndCapture.downmix(
                input.list, into: $0.baseAddress!, capacity: $0.count)
        }

        #expect(frames == 2)
        #expect(abs(output[0] - 3) < 1e-6)
        #expect(abs(output[1] - 14.0 / 3.0) < 1e-6)
    }

    @Test("the shortest populated buffer bounds every read")
    func clampsToShortestBuffer() {
        let input = BufferListFixture([
            .init(channels: 2, samples: [1, 3, 2, 4, 100, 100]),
            .init(channels: 1, samples: [5, 8]),
        ])
        var output = [Float](repeating: -1, count: 3)

        let frames = output.withUnsafeMutableBufferPointer {
            FarEndCapture.downmix(
                input.list, into: $0.baseAddress!, capacity: $0.count)
        }

        #expect(frames == 2)
        #expect(output[2] == -1)
    }

    @Test("a missing channel buffer is silence rather than a louder mix")
    func countsMissingBufferAsSilentChannels() {
        let input = BufferListFixture([
            .init(channels: 1, samples: [2, 4]),
            .init(channels: 1, samples: nil),
        ])
        var output = [Float](repeating: 0, count: 2)

        let frames = output.withUnsafeMutableBufferPointer {
            FarEndCapture.downmix(
                input.list, into: $0.baseAddress!, capacity: $0.count)
        }

        #expect(frames == 2)
        #expect(output == [1, 2])
    }

    @Test("destination capacity is a hard realtime write bound")
    func respectsDestinationCapacity() {
        let input = BufferListFixture([
            .init(channels: 1, samples: [1, 2, 3])
        ])
        var output = [Float](repeating: 0, count: 1)

        let frames = output.withUnsafeMutableBufferPointer {
            FarEndCapture.downmix(
                input.list, into: $0.baseAddress!, capacity: $0.count)
        }

        #expect(frames == 1)
        #expect(output == [1])
    }

    #if DEBUG
        @Test(
            "multi-buffer downmix allocates nothing on the realtime thread",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("multi-buffer downmix allocates nothing on the realtime thread")
    #endif
    func downmixIsRealtimeSafe() {
        let frames = 512
        let input = BufferListFixture([
            .init(channels: 2, samples: [Float](repeating: 0.25, count: frames * 2)),
            .init(channels: 1, samples: [Float](repeating: -0.125, count: frames)),
        ])
        var output = [Float](repeating: 0, count: frames)

        // Warm lazy runtime paths before the measured realtime interval.
        output.withUnsafeMutableBufferPointer {
            _ = FarEndCapture.downmix(
                input.list, into: $0.baseAddress!, capacity: $0.count)
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        output.withUnsafeMutableBufferPointer { destination in
            yun_rt_tripwire_mark_realtime(true)
            var iteration = 0
            while iteration < 10_000 {
                _ = FarEndCapture.downmix(
                    input.list,
                    into: destination.baseAddress!,
                    capacity: destination.count)
                iteration += 1
            }
            yun_rt_tripwire_mark_realtime(false)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before
        RoutingEngine.disableAllocationTripwire()

        print(
            "far-end 3ch × \(frames): \(elapsed / 10_000) ns/cycle, "
                + "\(allocations) realtime allocations")
        #expect(allocations == 0)
    }

    private func tapFormat(nonInterleaved: Bool) -> AudioStreamBasicDescription {
        let channels: UInt32 = 2
        let flags =
            kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | (nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0)
        let bytesPerFrame =
            UInt32(MemoryLayout<Float>.size) * (nonInterleaved ? 1 : channels)
        return AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }
}

private final class BufferListFixture {
    struct Buffer {
        let channels: Int
        let samples: [Float]?
    }

    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(_ buffers: [Buffer]) {
        list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        for (index, buffer) in buffers.enumerated() {
            let pointer: UnsafeMutablePointer<Float>?
            if let samples = buffer.samples {
                let allocated = UnsafeMutablePointer<Float>.allocate(
                    capacity: max(1, samples.count))
                if !samples.isEmpty {
                    samples.withUnsafeBufferPointer {
                        allocated.initialize(
                            from: $0.baseAddress!, count: samples.count)
                    }
                }
                storage.append(allocated)
                pointer = allocated
            } else {
                pointer = nil
            }
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(max(0, buffer.channels)),
                mDataByteSize: UInt32(
                    (buffer.samples?.count ?? 0) * MemoryLayout<Float>.size),
                mData: pointer.map { UnsafeMutableRawPointer($0) })
        }
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
}
