import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Recorder capacity")
struct RecorderCapacityTests {
    @Test("invalid rates and channel counts are refused before a file is opened")
    func invalidFormat() {
        let directory = FileManager.default.temporaryDirectory
        for rate in [Double.nan, .infinity, -1, 0, 7_999, 384_001] {
            #expect(throws: RecorderError.self) {
                _ = try Recorder(
                    directory: directory, format: .wav, channels: 2,
                    sampleRate: rate, timestamp: Date(timeIntervalSince1970: 0))
            }
        }
        for channels in [Int.min, -1, 0, 65, Int.max] {
            #expect(throws: RecorderError.self) {
                _ = try Recorder(
                    directory: directory, format: .wav, channels: channels,
                    sampleRate: 48_000, timestamp: Date(timeIntervalSince1970: 0))
            }
        }
    }

    @Test("ring storage has an exact thirty-two MiB sample ceiling")
    func ringCeiling() {
        let admitted = 384_000.0 * 4 * 2
        let refused = 384_000.0 * 4 * 6
        #expect(admitted <= Double(Recorder.maximumRingSamples))
        #expect(refused > Double(Recorder.maximumRingSamples))
    }

    @Test("a 48 kHz mix and thirty-one stereo stems fit one bounded session")
    func commonSessionFits() throws {
        let admitted = try #require(
            RecordingResourceAdmission.evaluate(
                sampleRate: 48_000,
                channelCounts: Array(repeating: 2, count: 32)))

        #expect(admitted.writerCount == 32)
        #expect(admitted.ringSamples == 12_288_000)
        #expect(admitted.ringBytes == 49_152_000)
        #expect(admitted.ringBytes < RecordingResourceAdmission.maximumRingBytes)
    }

    @Test("the thirty-two-writer ceiling admits its edge and rejects the next writer")
    func writerCeiling() {
        #expect(
            RecordingResourceAdmission.evaluate(
                sampleRate: 48_000,
                channelCounts: Array(
                    repeating: 1,
                    count: RecordingResourceAdmission.maximumWriters)) != nil)
        #expect(
            RecordingResourceAdmission.evaluate(
                sampleRate: 48_000,
                channelCounts: Array(
                    repeating: 1,
                    count: RecordingResourceAdmission.maximumWriters + 1)) == nil)
    }

    @Test("the 128 MiB byte ceiling admits its exact edge and rejects one float more")
    func byteCeiling() throws {
        let exactSamples =
            RecordingResourceAdmission.maximumRingBytes / MemoryLayout<Float>.stride
        #expect(
            RecordingResourceAdmission.admittedRingBytes(
                sampleCounts: [exactSamples])
                == RecordingResourceAdmission.maximumRingBytes)
        #expect(
            RecordingResourceAdmission.admittedRingBytes(
                sampleCounts: [exactSamples + 1]) == nil)
    }

    @Test("the pathological 384 kHz sixty-five-writer session is refused")
    func sessionCeilings() throws {
        #expect(
            RecordingResourceAdmission.evaluate(
                sampleRate: 384_000,
                channelCounts: Array(repeating: 2, count: 65)) == nil)

        let ten = try #require(
            RecordingResourceAdmission.evaluate(
                sampleRate: 384_000,
                channelCounts: Array(repeating: 2, count: 10)))
        #expect(ten.ringBytes == 122_880_000)
        #expect(ten.ringBytes <= RecordingResourceAdmission.maximumRingBytes)
        #expect(
            RecordingResourceAdmission.evaluate(
                sampleRate: 384_000,
                channelCounts: Array(repeating: 2, count: 11)) == nil)
    }

    @Test("session byte arithmetic fails closed on addition and multiplication overflow")
    func sessionArithmeticOverflow() {
        #expect(
            RecordingResourceAdmission.totalRingBytes(
                sampleCounts: [Int.max, 1]) == nil)
        #expect(
            RecordingResourceAdmission.totalRingBytes(
                sampleCounts: [Int.max / MemoryLayout<Float>.stride + 1]) == nil)
        #expect(RecordingResourceAdmission.totalRingBytes(sampleCounts: []) == nil)
        #expect(RecordingResourceAdmission.totalRingBytes(sampleCounts: [0]) == nil)
    }

    @Test("failed construction transfers every owner before reopening admission")
    func failedConstructionOwnershipOrdering() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let handoff = """
                        if let owner { _ = recorderFinaliser.submit(owner) }
                        recordingConstructionIsInFlight = false
            """
        let catchRetirement = """
                    } catch {
                        retireConstruction()
            """

        #expect(source.ranges(of: handoff).count == 2)
        #expect(source.ranges(of: catchRetirement).count == 2)
        #expect(
            !source.contains(
                """
                            recordingConstructionIsInFlight = false
                            stateLock.unlock()
                            retireConstruction()
                """))
    }
}
