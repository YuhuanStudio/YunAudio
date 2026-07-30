import SwiftUI
import Testing

@testable import YunAudioApp

/// What the stage does with a key.
///
/// Nothing here can post a key event at the window server, so this checks the
/// decision and says plainly that it does not check delivery. The decision is
/// where the mistakes are: a stage that swallows ⌘Q, or that gives the space
/// bar to a seek and the arrow keys to the lyric offset, is wrong in a way no
/// amount of correct event plumbing rescues.
@Suite("KTV keyboard")
struct KTVKeyCommandTests {

    @Test("the space bar plays and pauses")
    func spaceIsPlayPause() {
        #expect(KTVKeyCommand.resolve(.space) == .playPause)
    }

    @Test("the arrows move through the song, not the words")
    func arrowsSeek() {
        #expect(KTVKeyCommand.resolve(.leftArrow) == .skip(-5))
        #expect(KTVKeyCommand.resolve(.rightArrow) == .skip(5))
    }

    @Test("the brackets shift the words by the same step the buttons take")
    func bracketsNudgeTheLyrics() {
        #expect(KTVKeyCommand.resolve(KeyEquivalent("[")) == .nudgeLyrics(-0.5))
        #expect(KTVKeyCommand.resolve(KeyEquivalent("]")) == .nudgeLyrics(0.5))
        // The same half second the two arrows beside the words move by, so a
        // person who learns one has learnt the other.
        #expect(KTVKeyCommand.nudgeStep == 0.5)
    }

    @Test("full screen answers to f in either case")
    func fFillsTheScreen() {
        #expect(KTVKeyCommand.resolve(KeyEquivalent("f")) == .toggleFullScreen)
        #expect(KTVKeyCommand.resolve(KeyEquivalent("F"), modifiers: .shift) == .toggleFullScreen)
    }

    @Test("a held modifier belongs to somebody else")
    func modifiedKeysArePassedOn() {
        // ⌘W closes the window and ⌘Q quits. Handling a bare `f` and also
        // handling ⌘F would be the stage taking a shortcut it does not own.
        #expect(KTVKeyCommand.resolve(KeyEquivalent("f"), modifiers: .command) == nil)
        #expect(KTVKeyCommand.resolve(.space, modifiers: .command) == nil)
        #expect(KTVKeyCommand.resolve(.leftArrow, modifiers: .option) == nil)
        #expect(KTVKeyCommand.resolve(KeyEquivalent("["), modifiers: .control) == nil)
    }

    @Test("keys the stage has no use for are left alone")
    func unknownKeysAreIgnored() {
        #expect(KTVKeyCommand.resolve(KeyEquivalent("q")) == nil)
        #expect(KTVKeyCommand.resolve(.upArrow) == nil)
        #expect(KTVKeyCommand.resolve(.return) == nil)
        #expect(KTVKeyCommand.resolve(.escape) == nil)
    }
}
