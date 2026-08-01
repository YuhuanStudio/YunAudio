import Testing

@testable import YunAudioApp

/// What ⏮ does, which was one thing on the keyboard and a different thing on
/// screen.
///
/// The media key was wired to `goBackASong` and reached the queue. The button in
/// both presentations called `skipNowPlaying(by: -10)` and could not reach the
/// queue at all — so the same control, pressed two ways, did two different
/// things, and the one people can see was the one that did not work. The
/// capability was even advertised to the system, which is the definition of a
/// feature claimed and not delivered.
@Suite("what the previous button means")
struct TransportBackTests {

    @Test("near the start of a song it goes to the one before")
    func atTheStart() {
        #expect(TransportBack.of(position: 0, hasPreviousSong: true) == .previousSong)
        #expect(TransportBack.of(position: 2.9, hasPreviousSong: true) == .previousSong)
    }

    @Test("further in it starts this one again")
    func partWayThrough() {
        // Somebody who has sung two verses and reaches for ⏮ wants the verse
        // again. Taking the song away from them is the wrong answer and it is
        // the one every naive implementation gives.
        #expect(TransportBack.of(position: 40, hasPreviousSong: true) == .restart)
        #expect(TransportBack.of(position: 40, hasPreviousSong: false) == .restart)
    }

    @Test("pressing it twice walks back through the queue")
    func twice() {
        // The first press lands at zero, so the second press has a song before
        // it again. This is the behaviour that makes a three-second window the
        // right size: it has to survive its own effect.
        #expect(TransportBack.of(position: 1, hasPreviousSong: true) == .previousSong)
        #expect(TransportBack.of(position: 0, hasPreviousSong: true) == .previousSong)
    }

    @Test("with nothing before it, it does what it always did")
    func noQueue() {
        // Ten seconds back. A single song loaded on its own has no queue to
        // reach, and silently doing nothing would read as a broken button.
        #expect(TransportBack.of(position: 0, hasPreviousSong: false) == .rewind)
        #expect(TransportBack.of(position: 3, hasPreviousSong: false) == .rewind)
    }

    @Test("the window is a stated number rather than a literal in a switch")
    func theWindow() {
        #expect(TransportBack.withinSeconds == 3)
        // The boundary belongs to "restart", not to "previous": at exactly the
        // window somebody has been singing for three seconds.
        #expect(
            TransportBack.of(position: TransportBack.withinSeconds, hasPreviousSong: true)
                == .previousSong)
        #expect(
            TransportBack.of(
                position: TransportBack.withinSeconds + 0.01, hasPreviousSong: true)
                == .restart)
    }
}
