import Foundation
import Testing

@testable import YunAudioApp

/// How far a song has been transposed, remembered per song.
@Suite("Song keys")
struct SongKeysTests {

    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = UserDefaults(suiteName: "SongKeysTests-\(name)-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.description)
        return suite
    }

    @Test("a key is remembered for the song it belongs to")
    func keysAreRemembered() {
        let store = defaults()
        let song = "file:/Music/慢冷.mp3"
        #expect(SongKeys.semitones(for: song, in: store) == 0)
        #expect(SongKeys.shift(song, by: -2, in: store) == -2)
        #expect(SongKeys.semitones(for: song, in: store) == -2)
        // Somebody who takes a song down two takes it down two every time, and
        // being asked again each evening is the feature not working.
        #expect(SongKeys.semitones(for: "file:/Music/other.mp3", in: store) == 0)
    }

    @Test("the original key is the absence of an entry")
    func originalIsNotStored() {
        let store = defaults()
        let song = "file:/Music/慢冷.mp3"
        SongKeys.shift(song, by: 3, in: store)
        #expect(store.dictionary(forKey: SongKeys.key)?.count == 1)
        // Back to zero removes it, so the store holds only songs somebody
        // actually moved rather than a line per song ever played.
        SongKeys.shift(song, by: -3, in: store)
        #expect(store.dictionary(forKey: SongKeys.key)?.isEmpty == true)
    }

    @Test("six either way, and no further")
    func theRangeIsBounded() {
        let store = defaults()
        let song = "file:/Music/loud.mp3"
        // A time-pitch unit is stretching a mixed recording, not resynthesising
        // it, and the artefacts arrive long before the twelfth semitone.
        #expect(SongKeys.shift(song, by: 40, in: store) == 6)
        #expect(SongKeys.shift(song, by: -40, in: store) == -6)
        #expect(SongKeys.clamped(99) == 6)
        #expect(SongKeys.clamped(-99) == -6)
    }

    @Test("a song with no identity stores nothing")
    func anonymousSongsAreNotStored() {
        let store = defaults()
        #expect(SongKeys.shift("", by: 2, in: store) == 0)
        #expect(store.dictionary(forKey: SongKeys.key) == nil)
        #expect(SongKeys.semitones(for: "", in: store) == 0)
    }

    @Test("semitones reach the unit as cents")
    func centsAreWholeSemitones() {
        // The unit is set in cents because a decent transpose is rarely a whole
        // number of semitones; the control offered is, because a KTV key is.
        #expect(SongKeys.cents(forSemitones: 2) == 200)
        #expect(SongKeys.cents(forSemitones: -3) == -300)
        #expect(SongKeys.cents(forSemitones: 0) == 0)
        // Clamped on the way through, so a stored value from a future version
        // with a wider range cannot drive the unit past what it survives.
        #expect(SongKeys.cents(forSemitones: 99) == 600)
    }

    @Test("the control reads as a key rather than as a number")
    func titlesSaySomething() {
        #expect(SongKeys.title(0, original: "原調") == "原調")
        #expect(SongKeys.title(2, original: "原調") == "+2")
        // A minus sign rather than a hyphen: the two are a different width and
        // the control has a number either side of it that must not jump.
        #expect(SongKeys.title(-2, original: "原調") == "−2")
        #expect(SongKeys.title(-2, original: "原調").contains("-") == false)
    }
}
