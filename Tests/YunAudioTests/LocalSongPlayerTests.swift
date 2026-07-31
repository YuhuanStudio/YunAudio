import AVFoundation
import Foundation
import Testing

@testable import YunAudioApp

/// A song this application plays itself.
@Suite("Local song player")
struct LocalSongPlayerTests {

    /// Two seconds of a quiet tone, written where a test can open it.
    ///
    /// A real file rather than a fixture struct: the whole claim being made is
    /// that the length and the position come from the samples, and a stub would
    /// be asserting the arithmetic against itself.
    private func writeTone(
        seconds: Double = 2, rate: Double = 44_100, channels: AVAudioChannelCount = 1,
        named name: String = "tone.wav"
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunAudio-song-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let writer = try AVAudioFile(forWriting: file, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channelData = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                channelData[channel][frame] =
                    0.1 * Float(sin(2 * Double.pi * 440 * Double(frame) / rate))
            }
        }
        try writer.write(from: buffer)
        return file
    }

    @Test("a seek moves where the count starts from, not what it counts")
    func clockCarriesTheSeek() {
        // The node counts from the moment it was told to play, so after a seek
        // to 1:00 its own answer is zero and the song is a minute in. Getting
        // this wrong is a lyric sheet that jumps back to the first line every
        // time somebody drags the bar.
        let clock = LocalSongClock(startFrame: 60 * 48_000, sampleRate: 48_000, duration: 240)
        #expect(clock.position(playedFrames: 0) == 60)
        #expect(clock.position(playedFrames: 24_000) == 60.5)
        // Past the end, which a node does while its tail drains: the words
        // would otherwise run off the bottom of a song that had finished.
        #expect(clock.position(playedFrames: 300 * 48_000) == 240)
    }

    @Test("a clock with no file answers zero rather than a nonsense")
    func clockWithoutARate() {
        let empty = LocalSongClock()
        #expect(empty.position(playedFrames: 48_000) == 0)
        #expect(empty.frame(forSeconds: 12) == 0)
    }

    @Test("a seek lands on a frame inside the file")
    func seekClamps() {
        let clock = LocalSongClock(startFrame: 0, sampleRate: 44_100, duration: 10)
        #expect(clock.frame(forSeconds: 0) == 0)
        #expect(clock.frame(forSeconds: 1) == 44_100)
        // Half a sample rounds to a whole one; a request past either end is the
        // end. Neither is a failure worth reporting — dragging a bar to its
        // extreme is how everybody uses one.
        #expect(clock.frame(forSeconds: 1.000_005) == 44_100)
        #expect(clock.frame(forSeconds: -5) == 0)
        #expect(clock.frame(forSeconds: 1_000) == 441_000)
        #expect(clock.frame(forSeconds: .nan) == 0)
    }

    @Test("the length of a song is counted, not asked for")
    @MainActor
    func durationComesFromTheFile() throws {
        let file = try writeTone(seconds: 2, rate: 44_100)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let player = LocalSongPlayer()
        let song = try #require(player.open(file))
        // Exactly two seconds, because it is 88,200 frames over 44,100 — not
        // "about two" the way a player answering an Apple event is about two.
        #expect(song.duration == 2)
        // No tags on a written tone, so the file's own name is the title. A
        // song with no title at all is the one thing the stage cannot draw.
        #expect(song.title == "tone")
        #expect(song.artist.isEmpty)
        #expect(player.isPlaying == false)
        #expect(player.position == 0)
        player.stop()
        #expect(player.song == nil)
    }

    @Test("a file nothing can decode is refused rather than half-opened")
    @MainActor
    func rubbishIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunAudio-song-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-audio.wav")
        try Data("this is not a wave file".utf8).write(to: file)

        let player = LocalSongPlayer()
        #expect(player.open(file) == nil)
        // And nothing is left half-set: a song that failed to open must not be
        // the song the stage then tries to draw and the clock tries to follow.
        #expect(player.song == nil)
        #expect(player.isPlaying == false)
    }

    @Test("a second song with a different shape does not take the process with it")
    @MainActor
    func openingAnotherSongRebuildsTheGraph() throws {
        // The one that got away. Opening a stereo file after a mono one threw
        // out of `AVAudioEngineGraph::UpdateGraphAfterReconfig` — an
        // Objective-C exception, which Swift cannot catch, so it aborted the
        // whole application. A KTV evening is one song after another, so the
        // second one is not an edge case.
        //
        // The assertion is arriving at the end: an exception here would take
        // this process down rather than fail the expectation.
        let mono = try writeTone(seconds: 1, rate: 44_100, channels: 1, named: "one.wav")
        let stereo = try writeTone(seconds: 1, rate: 48_000, channels: 2, named: "two.wav")
        defer {
            try? FileManager.default.removeItem(at: mono.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: stereo.deletingLastPathComponent())
        }
        let player = LocalSongPlayer()
        #expect(player.open(mono)?.duration == 1)
        #expect(player.open(stereo)?.duration == 1)
        // And back the other way, because the rebuild has to work in both
        // directions and only one of them was ever exercised.
        #expect(player.open(mono)?.duration == 1)
        #expect(player.canCancelCentre == false)
        #expect(player.open(stereo) != nil)
        #expect(player.canCancelCentre)
        player.stop()
    }

    @Test("a paused song can be moved without being started")
    @MainActor
    func seekingWhilePausedMakesNoSound() throws {
        let file = try writeTone(seconds: 4, rate: 48_000)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let player = LocalSongPlayer()
        #expect(player.open(file) != nil)
        player.seek(to: 2.5)
        // Moved, and still silent: scheduling and immediately pausing would put
        // a fragment of the new position through the output, which is a click
        // somebody hears every time they drag the bar.
        #expect(player.position == 2.5)
        #expect(player.isPlaying == false)
        player.seek(to: 99)
        #expect(player.position == 4)
    }
}
