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
