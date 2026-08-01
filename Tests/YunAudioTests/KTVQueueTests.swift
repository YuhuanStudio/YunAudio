import Foundation
import Testing

@testable import YunAudioApp

/// The songs that have been put on, in the order they will be sung.
@Suite("KTV queue")
struct KTVQueueTests {

    private func song(_ name: String) -> URL {
        URL(fileURLWithPath: "/Music/\(name).mp3")
    }

    @Test("putting songs on an empty queue starts the first one")
    func appendingToAnEmptyQueueStarts() {
        var queue = KTVQueue()
        #expect(queue.isEmpty)
        #expect(queue.append([song("慢冷"), song("年少心動雨季")]) == song("慢冷"))
        #expect(queue.current == song("慢冷"))
        #expect(queue.upcoming == [song("年少心動雨季")])
    }

    @Test("putting a song on while somebody is singing does not interrupt them")
    func appendingWhileSingingChangesNothing() {
        var queue = KTVQueue()
        queue.append([song("慢冷")])
        // Nil rather than the new song: the answer is what to play, and the
        // answer here is "nothing, carry on".
        #expect(queue.append([song("往事只能回味")]) == nil)
        #expect(queue.current == song("慢冷"))
        #expect(queue.upcoming == [song("往事只能回味")])
    }

    @Test("插播 puts a song next, not last")
    func playNextInserts() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b"), song("c")])
        queue.playNext(song("mine"))
        // The whole point of the verb: after this one, not behind the other two.
        #expect(queue.upcoming == [song("mine"), song("b"), song("c")])
        #expect(queue.current == song("a"))
        #expect(queue.advance() == song("mine"))
    }

    @Test("插播 on an empty queue is just putting a song on")
    func playNextOnEmpty() {
        var queue = KTVQueue()
        queue.playNext(song("only"))
        #expect(queue.songs == [song("only")])
    }

    @Test("the end stops rather than starting the evening again")
    func theEndDoesNotWrap() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b")])
        #expect(queue.advance() == song("b"))
        // A machine that starts over by itself at two in the morning is one
        // somebody has to get up and turn off.
        #expect(queue.advance() == nil)
        #expect(queue.current == nil)
        #expect(queue.advance() == nil)
    }

    @Test("重唱 brings the same song round again")
    func repeatingOne() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b")])
        queue.repeatsOne = true
        #expect(queue.advance() == song("a"))
        #expect(queue.advance() == song("a"))
        // And switching it off carries on where the list was.
        queue.repeatsOne = false
        #expect(queue.advance() == song("b"))
    }

    @Test("going back stops at the first song")
    func goingBackDoesNotWrapEither() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b")])
        queue.advance()
        #expect(queue.goBack() == song("a"))
        // Pressing it again restarts this one rather than jumping to the end,
        // which is what every transport control on this stage already does.
        #expect(queue.goBack() == song("a"))
    }

    @Test("⏮ knows whether there is a song behind this one")
    func knowsWhatIsBehind() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b")])
        // At the first song there is nothing behind it, and ⏮ restarts this one
        // rather than being offered as a jump to nowhere.
        #expect(!queue.hasSongBefore)
        queue.advance()
        #expect(queue.hasSongBefore)
        // And after the last song ends, nothing is being sung at all.
        queue.advance()
        #expect(!queue.hasSongBefore)
    }

    @Test("taking out the song being sung plays whatever moved up")
    func removingTheCurrentSong() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b"), song("c")])
        queue.advance()
        #expect(queue.current == song("b"))
        #expect(queue.remove(at: 1) == song("c"))
        #expect(queue.current == song("c"))
        #expect(queue.songs == [song("a"), song("c")])
    }

    @Test("taking out a song above the current one leaves it alone")
    func removingAboveKeepsTheSong() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b"), song("c")])
        queue.advance()
        // Nil: nothing to change, the same song is still being sung — it has
        // only moved a line up the list.
        #expect(queue.remove(at: 0) == nil)
        #expect(queue.current == song("b"))
        #expect(queue.index == 0)
    }

    @Test("taking out the last song ends the evening")
    func removingTheLastEnds() {
        var queue = KTVQueue()
        queue.append([song("only")])
        #expect(queue.remove(at: 0) == nil)
        #expect(queue.current == nil)
        #expect(queue.isEmpty)
    }

    @Test("the same song twice is two entries")
    func duplicatesAreKept() {
        var queue = KTVQueue()
        // Two people wanting the same song is normal, and the second one is not
        // a mistake to be tidied away.
        queue.append([song("慢冷"), song("慢冷")])
        #expect(queue.songs.count == 2)
        #expect(queue.advance() == song("慢冷"))
        #expect(queue.advance() == nil)
    }

    @Test("pointing at a line plays that line")
    func choosingByPosition() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b"), song("c")])
        #expect(queue.choose(2) == song("c"))
        #expect(queue.current == song("c"))
        #expect(queue.choose(9) == nil)
        #expect(queue.current == song("c"))
    }

    @Test("clearing puts it back to nothing")
    func clearing() {
        var queue = KTVQueue()
        queue.append([song("a"), song("b")])
        queue.clear()
        #expect(queue.isEmpty)
        #expect(queue.current == nil)
        #expect(queue == KTVQueue())
    }
}

/// A queue that was written down and read back.
///
/// A KTV evening is a list somebody builds up over an hour, and quitting threw
/// it away — the songs were never in `Preferences` at all. Restoring it has one
/// hazard worth handling rather than ignoring, and these are it.
@Suite("the songs that were put on come back")
struct KTVQueueRestoreTests {

    private func temporaryFiles(_ count: Int) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunAudio-queue-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let url = directory.appendingPathComponent("song\(index).wav")
            try Data([0]).write(to: url)
            return url
        }
    }

    @Test("the list and the song being sung both come back")
    func roundTrip() throws {
        let files = try temporaryFiles(3)
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        let restored = KTVQueue.restored(paths: files.map(\.path), currentIndex: 1)
        #expect(restored.songs == files)
        #expect(restored.current == files[1])
    }

    @Test("a song that has been deleted since is dropped")
    func missingFiles() throws {
        let files = try temporaryFiles(3)
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: files[0])
        let restored = KTVQueue.restored(paths: files.map(\.path), currentIndex: 2)
        // Two left, and the marker still on the song it was on — not on the
        // number it had. Dropping an earlier file shifts every later index, so
        // following the number would leave it pointing at somebody else's song.
        #expect(restored.songs == [files[1], files[2]])
        #expect(restored.current == files[2])
    }

    @Test("and when the song being sung is the one that vanished, nothing is current")
    func currentFileMissing() throws {
        let files = try temporaryFiles(2)
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: files[1])
        let restored = KTVQueue.restored(paths: files.map(\.path), currentIndex: 1)
        #expect(restored.songs == [files[0]])
        // Better than guessing at a neighbour: the evening resumes with a list
        // and nothing playing, which is a state the transport already handles.
        #expect(restored.current == nil)
    }

    @Test("a list of songs that are all gone restores as an empty queue")
    func everythingMissing() throws {
        let restored = KTVQueue.restored(
            paths: ["/nowhere/a.wav", "/nowhere/b.wav"], currentIndex: 0)
        #expect(restored.isEmpty)
        #expect(restored.current == nil)
    }
}
