import Foundation
import Testing

@Suite("Stem recording clock")
struct StemRecordingClockTests {
    @Test("stem files declare the exact clock that produced their frames")
    func usesGraphSampleRate() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let start = try #require(
            source.range(of: "public func startStemRecording("))
        let remainder = source[start.lowerBound...]
        let end = try #require(remainder.range(of: "\n    }\n"))
        let body = String(remainder[..<end.upperBound])

        #expect(body.contains("sampleRate: graphSampleRate"))
        #expect(!body.contains("currentSampleRate"))
        #expect(!body.contains("?? 48000"))
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
}
