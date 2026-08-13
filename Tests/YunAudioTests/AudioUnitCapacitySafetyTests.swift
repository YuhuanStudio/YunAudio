import AudioToolbox
import AVFoundation
import Testing

@testable import YunAudioEngine

private final class MaliciousParameterReader: AudioUnitParameterPropertyReading {
    let advertisedByteCount: UInt32
    let returnedByteCount: UInt32
    let identifiers: [AudioUnitParameterID]
    let information: [AudioUnitParameterID: AudioUnitParameterInfo]
    private(set) var listReads = 0
    private(set) var informationReads: [AudioUnitParameterID] = []

    init(
        advertisedByteCount: UInt32, returnedByteCount: UInt32? = nil,
        identifiers: [AudioUnitParameterID] = [],
        information: [AudioUnitParameterID: AudioUnitParameterInfo] = [:]
    ) {
        self.advertisedByteCount = advertisedByteCount
        self.returnedByteCount = returnedByteCount ?? advertisedByteCount
        self.identifiers = identifiers
        self.information = information
    }

    func parameterListSize() -> (status: OSStatus, byteCount: UInt32) {
        (noErr, advertisedByteCount)
    }

    func readParameterList(
        into destination: UnsafeMutableRawPointer, byteCapacity: UInt32
    ) -> (status: OSStatus, returnedByteCount: UInt32) {
        listReads += 1
        let stride = MemoryLayout<AudioUnitParameterID>.stride
        let writable = min(identifiers.count, Int(byteCapacity) / stride)
        let output = destination.assumingMemoryBound(to: AudioUnitParameterID.self)
        for index in 0..<writable { output[index] = identifiers[index] }
        return (noErr, returnedByteCount)
    }

    func readParameterInfo(
        _ identifier: AudioUnitParameterID,
        into destination: UnsafeMutablePointer<AudioUnitParameterInfo>, byteCapacity: UInt32
    ) -> (status: OSStatus, returnedByteCount: UInt32) {
        informationReads.append(identifier)
        guard byteCapacity == UInt32(MemoryLayout<AudioUnitParameterInfo>.size),
            let info = information[identifier]
        else { return (kAudioUnitErr_InvalidParameter, 0) }
        destination.pointee = info
        return (noErr, byteCapacity)
    }
}

private func parameterInfo(
    named title: String?, fillWithoutNUL: UInt8? = nil
)
    -> AudioUnitParameterInfo
{
    var info = AudioUnitParameterInfo()
    info.minValue = 0
    info.maxValue = 1
    info.defaultValue = 0.5
    info.flags = [.flag_IsReadable, .flag_IsWritable]
    withUnsafeMutableBytes(of: &info.name) { bytes in
        for index in bytes.indices { bytes[index] = 0 }
        if let fillWithoutNUL {
            for index in bytes.indices { bytes[index] = fillWithoutNUL }
        } else if let title {
            for (index, byte) in title.utf8.prefix(max(0, bytes.count - 1)).enumerated() {
                bytes[index] = byte
            }
        }
    }
    return info
}

@Suite("Audio Unit capacity safety")
struct AudioUnitCapacitySafetyTests {
    @Test("pull storage accepts 4096 frames and refuses 4097")
    func pullStorageHonoursProcessingContract() throws {
        let accepted = AudioProcessingContract.maximumFramesPerSlice
        let source = UnsafeMutablePointer<Float>.allocate(capacity: accepted)
        source.initialize(repeating: 0, count: accepted)
        defer {
            source.deinitialize(count: accepted)
            source.deallocate()
        }

        let context = try #require(
            AudioUnitPullSourceContext.allocate(
                source: source, capacityFrames: accepted))
        defer { AudioUnitPullSourceContext.deallocate(context) }

        #expect(context.pointee.capacityFrames == 4_096)
        #expect(AudioUnitPullSourceContext.byteCount(for: 4_096) == 16_384)
        #expect(
            AudioUnitPullSourceContext.allocate(
                source: source, capacityFrames: 4_097) == nil)
        #expect(AudioUnitPullSourceContext.byteCount(for: 4_097) == nil)
    }

    @Test("a pull refuses a frame count beyond its source capacity")
    func excessivePullIsSilent() throws {
        let source = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        source.initialize(repeating: 99, count: 6)
        for index in 0..<4 { source[index] = Float(index + 1) }
        defer {
            source.deinitialize(count: 6)
            source.deallocate()
        }
        let context = try #require(
            AudioUnitPullSourceContext.allocate(source: source, capacityFrames: 4))
        defer { AudioUnitPullSourceContext.deallocate(context) }

        let destination = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        destination.initialize(repeating: -7, count: 8)
        defer {
            destination.deinitialize(count: 8)
            destination.deallocate()
        }
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(6 * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(destination))
        defer { free(buffers.unsafeMutablePointer) }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let status = audioUnitPullInput(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 6,
            buffers.unsafeMutablePointer)

        #expect(status == kAudioUnitErr_TooManyFramesToProcess)
        #expect((0..<4).allSatisfy { destination[$0] == 0 })
        #expect((4..<8).allSatisfy { destination[$0] == -7 })
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))
    }

    @Test("an undersized pull destination is cleared only within its byte capacity")
    func undersizedDestinationIsBounded() throws {
        let source = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        source.initialize(repeating: 0.25, count: 4)
        defer {
            source.deinitialize(count: 4)
            source.deallocate()
        }
        let context = try #require(
            AudioUnitPullSourceContext.allocate(source: source, capacityFrames: 4))
        defer { AudioUnitPullSourceContext.deallocate(context) }

        let destination = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        destination.initialize(repeating: 8, count: 6)
        defer {
            destination.deinitialize(count: 6)
            destination.deallocate()
        }
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(2 * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(destination))
        defer { free(buffers.unsafeMutablePointer) }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let status = audioUnitPullInput(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(status == kAudioUnitErr_InvalidParameter)
        #expect(destination[0] == 0)
        #expect(destination[1] == 0)
        #expect((2..<6).allSatisfy { destination[$0] == 8 })
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))
    }

    @Test("a valid pull copies every requested sample and no guard sample")
    func validPullCopiesExactPrefix() throws {
        let source = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        source.initialize(repeating: 0, count: 4)
        for index in 0..<4 { source[index] = Float(index + 1) / 4 }
        defer {
            source.deinitialize(count: 4)
            source.deallocate()
        }
        let context = try #require(
            AudioUnitPullSourceContext.allocate(source: source, capacityFrames: 4))
        defer { AudioUnitPullSourceContext.deallocate(context) }

        let destination = UnsafeMutablePointer<Float>.allocate(capacity: 5)
        destination.initialize(repeating: -1, count: 5)
        defer {
            destination.deinitialize(count: 5)
            destination.deallocate()
        }
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(4 * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(destination))
        defer { free(buffers.unsafeMutablePointer) }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let status = audioUnitPullInput(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(status == noErr)
        #expect((0..<4).allSatisfy { destination[$0] == Float($0 + 1) / 4 })
        #expect(destination[4] == -1)
        #expect(!flags.contains(.unitRenderAction_OutputIsSilence))
    }

    @Test("a pull refuses a non-mono or variable-length buffer list")
    func malformedBufferLayoutIsBounded() throws {
        let source = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        source.initialize(repeating: 0.5, count: 4)
        defer {
            source.deinitialize(count: 4)
            source.deallocate()
        }
        let context = try #require(
            AudioUnitPullSourceContext.allocate(source: source, capacityFrames: 4))
        defer { AudioUnitPullSourceContext.deallocate(context) }

        let destination = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        destination.initialize(repeating: 3, count: 6)
        defer {
            destination.deinitialize(count: 6)
            destination.deallocate()
        }
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(4 * MemoryLayout<Float>.stride),
            mData: UnsafeMutableRawPointer(destination))
        defer { free(buffers.unsafeMutablePointer) }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        buffers.unsafeMutablePointer.pointee.mNumberBuffers = 2
        let countStatus = audioUnitPullInput(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(countStatus == kAudioUnitErr_InvalidParameter)
        #expect((0..<4).allSatisfy { destination[$0] == 0 })
        #expect((4..<6).allSatisfy { destination[$0] == 3 })
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))

        destination.update(repeating: 6, count: 6)
        buffers.unsafeMutablePointer.pointee.mNumberBuffers = 1
        buffers[0].mNumberChannels = 2
        flags = AudioUnitRenderActionFlags()
        let channelStatus = audioUnitPullInput(
            UnsafeMutableRawPointer(context), &flags, &timestamp, 0, 4,
            buffers.unsafeMutablePointer)

        #expect(channelStatus == kAudioUnitErr_InvalidParameter)
        #expect((0..<4).allSatisfy { destination[$0] == 0 })
        #expect((4..<6).allSatisfy { destination[$0] == 6 })
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))
    }

    @Test("a non-aligned parameter-list size is rejected before allocation")
    func nonalignedPropertySizeIsRejected() {
        let reader = MaliciousParameterReader(advertisedByteCount: 5)

        #expect(AudioUnitPlugins.parameters(using: reader).isEmpty)
        #expect(reader.listReads == 0)
    }

    @Test("a huge parameter-list size is rejected before allocation")
    func hugePropertySizeIsRejected() {
        let stride = UInt32(MemoryLayout<AudioUnitParameterID>.stride)
        let huge = UInt32.max - UInt32.max % stride
        let reader = MaliciousParameterReader(advertisedByteCount: huge)

        #expect(AudioUnitPlugins.parameters(using: reader).isEmpty)
        #expect(reader.listReads == 0)
    }

    @Test("a returned parameter list cannot grow beyond its allocation")
    func returnedPropertySizeCannotGrow() {
        let stride = UInt32(MemoryLayout<AudioUnitParameterID>.stride)
        let reader = MaliciousParameterReader(
            advertisedByteCount: stride, returnedByteCount: stride * 2,
            identifiers: [1])

        #expect(AudioUnitPlugins.parameters(using: reader).isEmpty)
        #expect(reader.listReads == 1)
        #expect(reader.informationReads.isEmpty)
    }

    @Test("a shorter returned list exposes only its returned prefix")
    func returnedPropertyPrefixIsAuthoritative() {
        let stride = UInt32(MemoryLayout<AudioUnitParameterID>.stride)
        let reader = MaliciousParameterReader(
            advertisedByteCount: stride * 3, returnedByteCount: stride * 2,
            identifiers: [11, 12, 13],
            information: [
                11: parameterInfo(named: "One"),
                12: parameterInfo(named: "Two"),
                13: parameterInfo(named: "Unreturned"),
            ])

        let parameters = AudioUnitPlugins.parameters(using: reader)

        #expect(parameters.map(\.id) == ["p11", "p12"])
        #expect(parameters.map(\.title) == ["One", "Two"])
        #expect(reader.informationReads == [11, 12])
    }

    @Test("a fixed parameter name without NUL is decoded within its tuple")
    func unterminatedNameIsBounded() throws {
        let stride = UInt32(MemoryLayout<AudioUnitParameterID>.stride)
        let info = parameterInfo(named: nil, fillWithoutNUL: 0x58)
        let reader = MaliciousParameterReader(
            advertisedByteCount: stride, identifiers: [7], information: [7: info])

        let parameter = try #require(AudioUnitPlugins.parameters(using: reader).first)
        let tupleBytes = MemoryLayout.size(ofValue: info.name)

        #expect(parameter.id == "p7")
        #expect(parameter.title == String(repeating: "X", count: tupleBytes))
        #expect(parameter.title.utf8.count == tupleBytes)
    }
}
