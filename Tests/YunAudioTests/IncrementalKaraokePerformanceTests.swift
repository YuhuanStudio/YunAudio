import Foundation
import Testing

@testable import YunAudioEngine

/// The live score is cumulative, but its refresh cost and retained microphone
/// history must not be. These fixtures are deliberately song-length rather
/// than unit-test-length: a linear refresh looks harmless over ten seconds.
@Suite("Incremental karaoke scoring", .serialized)
struct IncrementalKaraokePerformanceTests {
    private let sungStep = 2_048.0 / 48_000

    @Test("a half-hour key score is numerically identical after history compaction")
    func halfHourKeyEquivalence() {
        let duration = 30.0 * 60
        let sung = stride(from: 0.0, to: duration, by: sungStep).enumerated().map {
            index, time in
            PitchSample(
                time: time,
                midi: [60.0, 64.4, 67.8, 61.2][index % 4])
        }
        let lyrics = stride(from: 0.0, to: duration, by: 8).enumerated().map {
            Lyrics.Line(time: $0.element, text: "line \($0.offset)")
        }
        let key = KeyDetector.Key(
            pitchClass: 0, isMinor: false, confidence: 1)
        let expected = KaraokeScore.keyScoreChronological(
            sung: sung,
            sungStep: sungStep,
            key: key,
            lyrics: lyrics,
            through: duration)

        var scorer = KaraokeScore.IncrementalKeyScorer(
            sungStep: sungStep,
            key: key,
            lyrics: lyrics)
        let actual = stream(
            sung,
            capacity: 4_096
        ) { retained, start, through in
            scorer.update(
                sung: retained,
                historyStartIndex: start,
                historyGeneration: 1,
                through: through)
        }

        expectEquivalent(actual, expected, tolerance: 1e-7)
        #expect(!scorer.missedHistory)
    }

    @Test("a half-hour exact score is numerically identical after history compaction")
    func halfHourExactEquivalence() {
        let duration = 30.0 * 60
        let reference = stride(from: 0.0, to: duration, by: 0.05).enumerated().map {
            index, time in
            PitchSample(time: time, midi: 60 + Double((index / 20) % 5))
        }
        let sung = stride(from: 0.0, to: duration, by: sungStep).enumerated().map {
            index, time in
            PitchSample(
                time: time,
                midi: 60 + Double((Int(time / 0.05) / 20) % 5)
                    + [0.0, 0.7, 1.4, -0.3][index % 4])
        }
        let lyrics = stride(from: 2.0, to: duration, by: 8).enumerated().map {
            Lyrics.Line(time: $0.element, text: "line \($0.offset)")
        }
        let expected = KaraokeScore.scoreChronological(
            sung: sung,
            sungStep: sungStep,
            reference: reference,
            referenceStep: 0.05,
            lyrics: lyrics,
            through: duration)

        var scorer = KaraokeScore.IncrementalExactScorer(
            sungStep: sungStep,
            reference: reference,
            referenceStep: 0.05,
            lyrics: lyrics)
        let actual = stream(
            sung,
            capacity: 4_096
        ) { retained, start, through in
            scorer.update(
                sung: retained,
                historyStartIndex: start,
                historyGeneration: 1,
                through: through)
        }

        expectEquivalent(actual, expected, tolerance: 1e-7)
        #expect(!scorer.missedHistory)
    }

    @Test("a seek cannot mix pitch from the preceding performance into the score")
    func historyGenerationResetsAccumulators() {
        let key = KeyDetector.Key(
            pitchClass: 0, isMinor: false, confidence: 1)
        let lyrics = [
            Lyrics.Line(time: 0, text: "first"),
            Lyrics.Line(time: 100, text: "second"),
        ]
        let first = stride(from: 0.0, to: 4.0, by: sungStep).map {
            PitchSample(time: $0, midi: 60)
        }
        let second = stride(from: 100.0, to: 104.0, by: sungStep).map {
            PitchSample(time: $0, midi: 61)
        }
        var scorer = KaraokeScore.IncrementalKeyScorer(
            sungStep: sungStep,
            key: key,
            lyrics: lyrics)
        _ = scorer.update(
            sung: first,
            historyGeneration: 1,
            through: 4)
        let actual = scorer.update(
            sung: second,
            historyGeneration: 2,
            through: 104)
        let expected = KaraokeScore.keyScoreChronological(
            sung: second,
            sungStep: sungStep,
            key: key,
            lyrics: lyrics,
            through: 104)

        expectEquivalent(actual, expected, tolerance: 1e-9)
    }

    @Test("an exact-reference score also resets across a forward seek")
    func exactHistoryGenerationResetsAccumulators() {
        let reference = stride(from: 0.0, to: 104.0, by: 0.05).map {
            PitchSample(time: $0, midi: 60)
        }
        let first = stride(from: 0.0, to: 4.0, by: sungStep).map {
            PitchSample(time: $0, midi: 60)
        }
        let second = stride(from: 100.0, to: 104.0, by: sungStep).map {
            PitchSample(time: $0, midi: 62)
        }
        var scorer = KaraokeScore.IncrementalExactScorer(
            sungStep: sungStep,
            reference: reference,
            referenceStep: 0.05,
            lyrics: [])
        _ = scorer.update(
            sung: first,
            historyGeneration: 1,
            through: 4)
        let actual = scorer.update(
            sung: second,
            historyGeneration: 2,
            through: 104)
        let expected = KaraokeScore.scoreChronological(
            sung: second,
            sungStep: sungStep,
            reference: reference,
            referenceStep: 0.05,
            through: 104)

        expectEquivalent(actual, expected, tolerance: 1e-9)
    }

    @Test("one hour of live pitch stays below the configured memory ceiling")
    func oneHourHistoryIsBounded() throws {
        let singer = try #require(SingerPitch(sampleRate: 48_000))
        let capacity = 4_096
        let sampleCount = Int(3_600 / singer.sampleInterval)
        singer.historyCapacity = capacity
        singer.reset(at: 0)

        for index in 0..<sampleCount {
            singer.appendPitchForTesting(
                PitchSample(
                    time: Double(index) * singer.sampleInterval,
                    midi: 60 + Double(index % 12)))
        }

        let retainedBytes = singer.samples.count * MemoryLayout<PitchSample>.stride
        print(
            "one-hour singer history: \(sampleCount) pitches, "
                + "\(singer.samples.count) retained, \(retainedBytes) bytes")
        #expect(sampleCount > 84_000)
        #expect(singer.samples.count <= capacity * 2)
        #expect(singer.historyStartIndex + singer.samples.count == sampleCount)
        #expect(retainedBytes <= 128 * 1_024)
    }

    #if DEBUG
        @Test(
            "one-hour incremental refresh stays below its latency budget",
            .disabled("timing evidence requires an optimised build"))
    #else
        @Test("one-hour incremental refresh stays below its latency budget")
    #endif
    func oneHourRefreshCost() {
        let duration = 60.0 * 60
        let sung = stride(from: 0.0, to: duration, by: sungStep).map {
            PitchSample(time: $0, midi: 60)
        }
        let lyrics = stride(from: 0.0, to: duration, by: 8).map {
            Lyrics.Line(time: $0, text: "line")
        }
        let key = KeyDetector.Key(
            pitchClass: 0, isMinor: false, confidence: 1)
        var scorer = KaraokeScore.IncrementalKeyScorer(
            sungStep: sungStep,
            key: key,
            lyrics: lyrics)
        _ = scorer.update(
            sung: sung,
            historyGeneration: 1,
            through: duration)

        let started = DispatchTime.now().uptimeNanoseconds
        var result = KaraokeScore.none
        for _ in 0..<100 {
            result = scorer.update(
                sung: sung,
                historyGeneration: 1,
                through: duration)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let average = elapsed / 100

        print(
            "one-hour incremental key refresh: \(average) ns, "
                + "\(sung.count) historical pitches")
        #expect(result.percentage > 99)
        #expect(average < 2_000_000)
    }

    private func stream(
        _ samples: [PitchSample],
        capacity: Int,
        update: ([PitchSample], Int, Double) -> KaraokeScore
    ) -> KaraokeScore {
        var retained: [PitchSample] = []
        retained.reserveCapacity(capacity * 2 + 256)
        var historyStart = 0
        var cursor = 0
        var result = KaraokeScore.none
        while cursor < samples.count {
            let end = min(samples.count, cursor + 256)
            retained.append(contentsOf: samples[cursor..<end])
            if retained.count > capacity * 2 {
                let discarded = retained.count - capacity
                retained.removeFirst(discarded)
                historyStart += discarded
            }
            result = update(retained, historyStart, samples[end - 1].time)
            cursor = end
        }
        return result
    }

    private func expectEquivalent(
        _ actual: KaraokeScore,
        _ expected: KaraokeScore,
        tolerance: Double
    ) {
        #expect(abs(actual.percentage - expected.percentage) <= tolerance)
        #expect(abs(actual.onPitchSeconds - expected.onPitchSeconds) <= tolerance)
        #expect(abs(actual.nearPitchSeconds - expected.nearPitchSeconds) <= tolerance)
        #expect(abs(actual.silentSeconds - expected.silentSeconds) <= tolerance)
        #expect(abs(actual.referenceSeconds - expected.referenceSeconds) <= tolerance)
        #expect(abs(actual.sungSeconds - expected.sungSeconds) <= tolerance)
        if let actualError = actual.meanErrorSemitones,
            let expectedError = expected.meanErrorSemitones
        {
            #expect(abs(actualError - expectedError) <= tolerance)
        } else {
            #expect(
                actual.meanErrorSemitones == nil
                    && expected.meanErrorSemitones == nil)
        }
        #expect(actual.lines.count == expected.lines.count)
        for (actualLine, expectedLine) in zip(actual.lines, expected.lines) {
            #expect(actualLine.index == expectedLine.index)
            #expect(actualLine.time == expectedLine.time)
            #expect(actualLine.text == expectedLine.text)
            #expect(
                abs(actualLine.referenceSeconds - expectedLine.referenceSeconds)
                    <= tolerance)
            #expect(
                abs(actualLine.onPitchSeconds - expectedLine.onPitchSeconds)
                    <= tolerance)
            #expect(
                abs(actualLine.nearPitchSeconds - expectedLine.nearPitchSeconds)
                    <= tolerance)
            #expect(abs(actualLine.percentage - expectedLine.percentage) <= tolerance)
        }
    }
}
