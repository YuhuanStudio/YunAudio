import AVFoundation
import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Melody taken from the song file")
struct SongMelodyExtractionTests {

    /// Writes a file of sung-range tones, so the answer is known before it is
    /// asked for.
    private func writeTones(
        _ notes: [(midi: Double, seconds: Double)],
        rate: Double = 48_000,
        channels: AVAudioChannelCount = 2,
        harmonics: Bool = true
    ) throws -> URL {
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: rate, channels: channels))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melody-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var phase = 0.0
        for note in notes {
            let hertz = 440 * pow(2, (note.midi - 69) / 12)
            let frames = AVAudioFrameCount(note.seconds * rate)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let data = try #require(buffer.floatChannelData)
            let step = 2 * Double.pi * hertz / rate
            for frame in 0..<Int(frames) {
                // A voice is not a sine. Two harmonics give the correlation
                // curve something to be wrong about, which is the case the
                // learned head exists for.
                var value = sin(phase)
                if harmonics {
                    value += 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)
                    value /= 1.75
                }
                for channel in 0..<Int(channels) {
                    data[channel][frame] = Float(value * 0.5)
                }
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            try file.write(from: buffer)
        }
        return url
    }

    /// The number the whole feature rests on: a melody read from the file has
    /// to be the melody that is in it.
    @Test("the notes come back as the notes that were written")
    func extractedNotesMatchTheWrittenOnes() throws {
        let written: [(midi: Double, seconds: Double)] = [
            (57, 1.0),  // A3, 220 Hz
            (60, 1.0),  // C4
            (64, 1.0),  // E4
            (69, 1.0),  // A4, 440 Hz
        ]
        let url = try writeTones(written)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try SongMelody.extract(from: url)

        #expect(result.analysedSeconds > 3.5)
        #expect(result.isUsable == (result.pitchedSeconds >= SongMelody.leastUsableSeconds))
        #expect(!result.samples.isEmpty)

        // The middle of each note, away from the boundaries where one window
        // straddles two pitches.
        for (index, note) in written.enumerated() {
            let centre = Double(index) + 0.5
            let nearby = result.samples.filter { abs($0.time - centre) < 0.25 }
            #expect(!nearby.isEmpty, "no samples near \(centre) s")
            guard !nearby.isEmpty else { continue }
            let median = nearby.map(\.midi).sorted()[nearby.count / 2]
            // Within a quarter tone. Anything looser would not be a melody.
            #expect(
                abs(median - note.midi) < 0.5,
                "at \(centre) s expected MIDI \(note.midi), read \(median)")
        }
    }

    /// An instrumental has no sung line, and the reference must say so instead
    /// of scoring somebody against stray harmonics — which is the failure this
    /// feature exists to end, not to repeat.
    @Test("silence is not a melody")
    func silenceIsRefused() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 30))
        buffer.frameLength = 48_000 * 30
        try file.write(from: buffer)

        let result = try SongMelody.extract(from: url)

        #expect(result.analysedSeconds > 25)
        #expect(result.pitchedSeconds < SongMelody.leastUsableSeconds)
        #expect(!result.isUsable)
    }

    /// Mono files are ordinary, and the mixing path must not drop them.
    @Test("a mono file is read as itself")
    func monoIsRead() throws {
        let url = try writeTones([(62, 2.0)], channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try SongMelody.extract(from: url)
        let nearby = result.samples.filter { abs($0.time - 1.0) < 0.4 }
        #expect(!nearby.isEmpty)
        let median = nearby.map(\.midi).sorted()[max(0, nearby.count / 2)]
        #expect(abs(median - 62) < 0.5, "read \(median)")
    }

    /// The caller owns the thread, so it has to be able to take it back.
    @Test("cancellation is honoured")
    func cancellationStops() throws {
        let url = try writeTones([(60, 20.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SongMelody.Failure.self) {
            _ = try SongMelody.extract(from: url, isCancelled: { true })
        }
    }

    /// The reference is sampled at the interval the scorer already samples the
    /// MIDI melody at, because the two have to be interchangeable.
    @Test("the hop matches the scorer's reference interval")
    func hopMatchesTheScorer() {
        #expect(SongMelody.hopSeconds == KaraokeScore.referenceInterval)
    }
}
