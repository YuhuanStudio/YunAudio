import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

/// Knowing when to come in.
@Suite("KTV count-in")
struct KTVCountInTests {

    private func song(offset: Double = 0) -> Lyrics {
        var lyrics = Lyrics.parse(
            """
            [00:10.00]第一句
            [00:14.00]第二句
            [00:18.00]
            [00:30.00]第三句
            """)!
        lyrics.offset = offset
        return lyrics
    }

    @Test("the intro is counted, even where the file left no silence")
    func theIntroIsCounted() throws {
        let lyrics = song()
        let seconds = try #require(
            KTVCountIn.secondsUntilWords(in: lyrics, playing: nil, position: 7, nudge: 0))
        #expect(abs(seconds - 3) < 0.001)
        #expect(KTVCountIn.remaining(seconds: seconds) == 3)
    }

    @Test("nothing is counted over a line being sung")
    func singingIsNotCountedThrough() {
        // Line 0 is running. A count here would be counting into line 1 while
        // line 0 is still being sung.
        #expect(
            KTVCountIn.secondsUntilWords(in: song(), playing: 0, position: 12, nudge: 0) == nil)
    }

    @Test("the return from an instrumental break is counted")
    func theBreakIsCounted() throws {
        // Index 2 is the rest at 18 s; the words come back at 30 s.
        let seconds = try #require(
            KTVCountIn.secondsUntilWords(in: song(), playing: 2, position: 28, nudge: 0))
        #expect(abs(seconds - 2) < 0.001)
        #expect(KTVCountIn.remaining(seconds: seconds) == 2)
    }

    @Test("a long wait is not a four-second count")
    func longWaitsShowNothing() {
        // Twelve seconds of break left. A count that runs the whole way is a
        // distraction rather than a cue.
        let seconds = KTVCountIn.secondsUntilWords(
            in: song(), playing: 2, position: 18, nudge: 0)
        #expect(seconds == 12)
        #expect(KTVCountIn.remaining(seconds: seconds) == nil)
    }

    @Test("the count follows every shift applied to the words")
    func shiftsAreUndone() throws {
        // The words are held back two seconds, so the music reaches the first
        // line two seconds later than the file says.
        let seconds = try #require(
            KTVCountIn.secondsUntilWords(
                in: song(offset: -2), playing: nil, position: 9, nudge: 0))
        #expect(abs(seconds - 3) < 0.001)

        // And the live nudge counts the same way.
        let nudged = try #require(
            KTVCountIn.secondsUntilWords(in: song(), playing: nil, position: 8, nudge: -1))
        #expect(abs(nudged - 3) < 0.001)
    }

    @Test("a rest at the end of the file counts into nothing")
    func nothingAfterTheLastWordsIsNotCounted() {
        let lyrics = Lyrics.parse("[00:10.00]最後一句\n[00:20.00]")!
        #expect(
            KTVCountIn.secondsUntilWords(in: lyrics, playing: 1, position: 21, nudge: 0) == nil)
    }

    @Test("the moment the words start there is nothing left to count")
    func zeroIsNotCounted() {
        #expect(KTVCountIn.remaining(seconds: 0) == nil)
        #expect(KTVCountIn.remaining(seconds: -1) == nil)
        #expect(KTVCountIn.remaining(seconds: nil) == nil)
        // The last whole second still shows one dot rather than none.
        #expect(KTVCountIn.remaining(seconds: 0.2) == 1)
        #expect(KTVCountIn.remaining(seconds: 4) == 4)
    }

    @Test("a line index the song does not have is not counted from")
    func nonsenseIndexesAreRefused() {
        #expect(
            KTVCountIn.secondsUntilWords(in: song(), playing: 99, position: 1, nudge: 0) == nil)
    }
}
