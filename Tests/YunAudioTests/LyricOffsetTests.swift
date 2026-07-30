import Foundation
import Testing

@testable import YunAudioApp

/// A nudge that survives the song being played again.
///
/// A published `.lrc` is timed against whatever master its author had, and
/// routinely not the recording being played. 「慢冷」 arrives with its first
/// line at the very start and no lead-in, so the stage lights a line before
/// anyone sings — and no better file exists to find, because the words are
/// right and only the clock is wrong.
@Suite("Lyric offsets")
struct LyricOffsetTests {
    private func store() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "yunaudio.tests.\(UUID().uuidString)")!
        return defaults
    }

    @Test("a song with no nudge is not shifted")
    func absentIsZero() {
        #expect(LyricOffsets.offset(for: "慢冷", in: store()) == 0)
    }

    @Test("a nudge accumulates and comes back")
    func nudgesAccumulate() {
        let defaults = store()
        #expect(LyricOffsets.nudge("慢冷", by: -0.5, in: defaults) == -0.5)
        #expect(LyricOffsets.nudge("慢冷", by: -0.5, in: defaults) == -1.0)
        #expect(LyricOffsets.offset(for: "慢冷", in: defaults) == -1.0)
        // And it is that song's, not everyone's.
        #expect(LyricOffsets.offset(for: "來不及愛妳", in: defaults) == 0)
    }

    @Test("returning to zero removes the entry rather than storing a zero")
    func zeroIsAbsence() {
        let defaults = store()
        LyricOffsets.nudge("慢冷", by: -0.5, in: defaults)
        LyricOffsets.nudge("慢冷", by: 0.5, in: defaults)
        // A file that gains a line per song ever nudged is one nobody can read
        // and nothing can prune.
        let all = defaults.dictionary(forKey: LyricOffsets.key) as? [String: Double]
        #expect(all?["慢冷"] == nil)
        #expect(LyricOffsets.offset(for: "慢冷", in: defaults) == 0)
    }

    @Test("a nudge is bounded, and nonsense is not stored")
    func boundsHold() {
        let defaults = store()
        #expect(LyricOffsets.nudge("慢冷", by: -900, in: defaults) == -LyricOffsets.limit)
        #expect(LyricOffsets.nudge("慢冷", by: 9_000, in: defaults) == LyricOffsets.limit)
        #expect(LyricOffsets.clamped(.nan) == 0)
        // Infinity is not a very large nudge, it is a bad value: it becomes
        // no nudge rather than the largest one, so a corrupted store cannot
        // silently shift a song by the maximum.
        #expect(LyricOffsets.clamped(.infinity) == 0)
    }

    @Test("clearing puts the song back where the file had it")
    func clearingRestoresTheFile() {
        let defaults = store()
        LyricOffsets.nudge("慢冷", by: -3, in: defaults)
        LyricOffsets.clear("慢冷", in: defaults)
        #expect(LyricOffsets.offset(for: "慢冷", in: defaults) == 0)
    }

    @Test("a song with no identity cannot be nudged into a nameless entry")
    func emptyIdentityIsIgnored() {
        let defaults = store()
        #expect(LyricOffsets.nudge("", by: -1, in: defaults) == 0)
        #expect(defaults.dictionary(forKey: LyricOffsets.key) == nil)
    }
}
