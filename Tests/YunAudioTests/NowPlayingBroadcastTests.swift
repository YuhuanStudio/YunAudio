import Foundation
import Testing

@testable import YunAudioApp

/// What this application tells macOS about the song it is playing.
///
/// The decisions worth arguing with are all here rather than in the framework
/// shim: what the buttons may do, what the playhead reads at the end of a song,
/// and — the one with a cost attached — when a republish is warranted at all.
@Suite("what the system is told is playing")
struct NowPlayingBroadcastTests {

    private func broadcast(
        title: String = "慢冷", artist: String = "梁靜茹", album: String = "崇拜",
        duration: Double = 258, elapsed: Double = 30, isPlaying: Bool = true,
        hasQueuedSong: Bool = false, repeatsOne: Bool = false,
        hasPreviousSong: Bool = false, hasArtwork: Bool = true
    ) -> NowPlayingBroadcast {
        NowPlayingBroadcast.forOurOwnSong(
            title: title, artist: artist, album: album, duration: duration,
            elapsed: elapsed, isPlaying: isPlaying, hasQueuedSong: hasQueuedSong,
            repeatsOne: repeatsOne, hasPreviousSong: hasPreviousSong,
            hasArtwork: hasArtwork)
    }

    @Test("the song's own details go out as they are")
    func detailsCarry() {
        let out = broadcast()
        #expect(out.title == "慢冷")
        #expect(out.artist == "梁靜茹")
        #expect(out.album == "崇拜")
        #expect(out.duration == 258)
        #expect(out.isPlaying)
    }

    @Test("the playhead never runs off the end of the song")
    func elapsedIsClamped() {
        // A player node counts on while the tail drains, and a lock screen
        // reading 4:31 of a 4:12 song looks like the application lost it.
        #expect(broadcast(duration: 258, elapsed: 271).elapsed == 258)
        #expect(broadcast(duration: 258, elapsed: -3).elapsed == 0)
        #expect(broadcast(duration: 258, elapsed: .nan).elapsed == 0)
        // A file whose length is unknown has nothing to clamp against, so the
        // position still has to come through.
        #expect(broadcast(duration: 0, elapsed: 42).elapsed == 42)
    }

    @Test("a length that is not a number is no length rather than a bad one")
    func durationIsSane() {
        #expect(broadcast(duration: .nan).duration == 0)
        #expect(broadcast(duration: -5).duration == 0)
        #expect(broadcast(duration: .infinity).duration == 0)
    }

    @Test("skip forward is offered only when it has somewhere to go")
    func skipForward() {
        #expect(!broadcast(hasQueuedSong: false, repeatsOne: false).canSkipForward)
        #expect(broadcast(hasQueuedSong: true).canSkipForward)
        // 重唱 counts: at the end of the list, where it goes is the top of this
        // song.
        #expect(broadcast(hasQueuedSong: false, repeatsOne: true).canSkipForward)
    }

    @Test("skip back is offered even at the first song, because it restarts it")
    func skipBackward() {
        #expect(broadcast(hasPreviousSong: false).canSkipBackward)
        #expect(broadcast(hasPreviousSong: true).canSkipBackward)
        // Nothing to restart and nothing before it is the one case where the
        // button really has nowhere to go.
        #expect(!broadcast(duration: 0, hasPreviousSong: false).canSkipBackward)
    }

    @Test("the first thing to say is always worth saying")
    func firstPublishAlways() {
        #expect(broadcast().needsPublishing(after: nil))
    }

    @Test("a song playing steadily is not republished twenty times a second")
    func steadyPlaybackIsQuiet() {
        // The reason this value exists. The system advances the playhead itself
        // from the rate, so the poll must not push a new dictionary every
        // frame — that would be the same cost as the polling this application
        // went to some trouble to avoid.
        let at30 = broadcast(elapsed: 30)
        #expect(!broadcast(elapsed: 30.05).needsPublishing(after: at30))
        #expect(!broadcast(elapsed: 30.9).needsPublishing(after: at30))
    }

    @Test("but a seek is")
    func seekingIsPublished() {
        let at30 = broadcast(elapsed: 30)
        #expect(broadcast(elapsed: 90).needsPublishing(after: at30))
        #expect(broadcast(elapsed: 5).needsPublishing(after: at30))
        #expect(broadcast(elapsed: 31.0).needsPublishing(after: at30))
    }

    @Test("and so is anything anybody would see standing still")
    func visibleChangesArePublished() {
        let playing = broadcast()
        #expect(broadcast(isPlaying: false).needsPublishing(after: playing))
        #expect(broadcast(title: "年少心動雨季").needsPublishing(after: playing))
        #expect(broadcast(artist: "另一個人").needsPublishing(after: playing))
        #expect(broadcast(album: "另一張").needsPublishing(after: playing))
        #expect(broadcast(duration: 300).needsPublishing(after: playing))
        #expect(broadcast(hasArtwork: false).needsPublishing(after: playing))
        // The buttons too: a ⏭ that has become available while the dictionary
        // says otherwise is a control somebody presses and nothing happens.
        #expect(broadcast(hasQueuedSong: true).needsPublishing(after: playing))
    }

    @Test("pausing and resuming in place both go out")
    func pauseAndResume() {
        // Same position, different rate. Without this the lock screen carries
        // on counting through a paused song.
        let playing = broadcast(elapsed: 30, isPlaying: true)
        let paused = broadcast(elapsed: 30, isPlaying: false)
        #expect(paused.needsPublishing(after: playing))
        #expect(playing.needsPublishing(after: paused))
    }
}
