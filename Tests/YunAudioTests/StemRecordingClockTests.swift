import Foundation
import Testing

@Suite("Stem recording clock")
struct StemRecordingClockTests {
    @Test("recording files use one graph-clock snapshot taken under the state lock")
    func usesGraphSampleRate() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)

        try assertClockSnapshot(
            in: source, function: "public func startRecordingSession(",
            offLockInitialisers: 3)
        try assertClockSnapshot(
            in: source, function: "public func startStemRecording(",
            offLockInitialisers: 1)
    }

    @Test("misdeclaring 44.1 kHz frames as 48 kHz has an audible exact cost")
    func quantifiesClockMismatch() {
        let capturedRate = 44_100.0
        let declaredRate = 48_000.0
        let speed = declaredRate / capturedRate
        let duration = capturedRate / declaredRate
        let semitones = 12 * log2(speed)

        #expect(abs(speed - 1.088_435_374_149_66) < 1e-12)
        #expect(abs(duration - 0.918_75) < 1e-12)
        #expect(abs(semitones - 1.467_069_000_611_98) < 1e-12)
    }

    private func assertClockSnapshot(
        in source: String, function: String, offLockInitialisers: Int
    ) throws {
        let start = try #require(source.range(of: function))
        let remainder = source[start.lowerBound...]
        let end = try #require(remainder.range(of: "\n    }\n"))
        let body = remainder[..<end.upperBound]
        let lock = try #require(body.range(of: "stateLock.lock()"))
        let snapshot = try #require(
            body.range(
                of: "let sampleRate = graphSampleRate",
                range: lock.upperBound..<body.endIndex))
        let unlock = try #require(
            body.range(
                of: "stateLock.unlock()",
                range: snapshot.upperBound..<body.endIndex))
        let construction = body[unlock.upperBound...]

        #expect(lock.lowerBound < snapshot.lowerBound)
        #expect(snapshot.lowerBound < unlock.lowerBound)
        #expect(!construction.contains("graphSampleRate"))
        #expect(
            construction.ranges(of: "sampleRate: sampleRate").count
                == offLockInitialisers)
        #expect(!body.contains("currentSampleRate"))
        #expect(!body.contains("?? 48000"))
    }
}
