import AVFoundation
import Foundation
import Testing

@testable import YunAudioApp

/// What reading a song's tags actually costs.
///
/// `LocalSongPlayer.metadata(of:)` uses the synchronous accessors, which are
/// deprecated in favour of an `await load(_:)`, and the comment justifying that
/// says the work is "tens of microseconds". Nobody had measured it. This does,
/// because the justification is the only thing keeping three deprecation
/// warnings in the build, and a justification with no number is an opinion.
///
/// It matters beyond tidiness: `open(_:)` is called on the queue advancing to
/// the next song, between one song ending and the next starting. Whatever this
/// costs is silence at the top of the next song.
@Suite("song metadata cost")
struct SongMetadataCostTests {

    /// A short file to read tags off. A WAV carries none, which is the point:
    /// what is being timed is opening the asset and asking, not decoding a tag
    /// block, and that is the part every file pays.
    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-cost-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.2
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test("reading tags off a song is not a pause between songs")
    func metadataIsCheap() throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Once first, uncounted: the first asset in a process pays for
        // AVFoundation waking up, and that is not what any song after the first
        // one pays.
        _ = AVURLAsset(url: url).commonMetadata

        // The best of several batches rather than one batch.
        //
        // What is being asked is how long the call takes, and the answer is a
        // floor: no batch can run faster than the work costs, but any batch can
        // run slower because the machine did something else in the middle. One
        // batch therefore measures the work plus whatever the scheduler did,
        // and the whole suite runs its cases in parallel — so this passed alone
        // at 0.3 ms and failed in the suite, which is a fact about the test
        // machine and not about the metadata reader.
        //
        // Taking the minimum measures the thing itself. A regression makes
        // every batch slow and the floor rises with them; contention makes one
        // batch slow and the floor does not move.
        let runs = 20
        var best = Double.infinity
        for _ in 0..<5 {
            let began = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<runs {
                let asset = AVURLAsset(url: url)
                let items = asset.commonMetadata
                _ =
                    AVMetadataItem.metadataItems(
                        from: items, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common
                    ).first?.stringValue
            }
            let elapsed =
                Double(DispatchTime.now().uptimeNanoseconds - began) / Double(runs) / 1_000_000
            best = min(best, elapsed)
        }
        let each = best
        print(String(format: "song metadata read: %.3f ms (best of 5 batches of 20)", each))

        // Two milliseconds, against a gap between songs nobody can hear below
        // about twenty. Deliberately loose: this is a ceiling that says "not a
        // pause", not a benchmark to defend to three decimal places, and a test
        // machine under load must not turn a justified synchronous call into a
        // red line.
        #expect(each < 2.0)
    }
}
