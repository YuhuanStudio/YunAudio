import Foundation
import Testing

@testable import YunAudioApp

/// Looking around the words without the song running away.
@Suite("KTV lyric browsing")
struct KTVLyricBrowseTests {

    @Test("at rest the column follows the song")
    func restingFollowsThePlayingLine() {
        let browse = KTVLyricBrowse()
        #expect(!browse.isBrowsing)
        #expect(browse.centre(whilePlaying: 12) == 12)
        #expect(browse.centre(whilePlaying: nil) == nil)
    }

    @Test("a brush of the trackpad does not take the column off the song")
    func smallTravelDoesNothing() {
        var browse = KTVLyricBrowse()
        // Well under one line's worth, which is what a trackpad reports many
        // times a second while a hand rests on it.
        browse.scroll(by: 6, playing: 20, lineCount: 60)
        browse.scroll(by: 5, playing: 20, lineCount: 60)
        #expect(!browse.isBrowsing)
        #expect(browse.centre(whilePlaying: 20) == 20)
    }

    @Test("small travel accumulates rather than being thrown away")
    func travelAccumulates() {
        var browse = KTVLyricBrowse()
        // Six events of five points is thirty — past one line, not two.
        for _ in 0..<6 { browse.scroll(by: 5, playing: 20, lineCount: 60) }
        #expect(browse.line == 19)
    }

    @Test("dragging the words down shows what came before")
    func directionMatchesThePlatform() {
        var browse = KTVLyricBrowse()
        browse.scroll(by: KTVLyricBrowse.pointsPerLine * 3, playing: 20, lineCount: 60)
        #expect(browse.line == 17)

        var other = KTVLyricBrowse()
        other.scroll(by: -KTVLyricBrowse.pointsPerLine * 3, playing: 20, lineCount: 60)
        #expect(other.line == 23)
    }

    @Test("the column stops at both ends of the song")
    func browsingIsClamped() {
        var browse = KTVLyricBrowse()
        browse.scroll(by: KTVLyricBrowse.pointsPerLine * 500, playing: 20, lineCount: 60)
        #expect(browse.line == 0)

        var late = KTVLyricBrowse()
        late.scroll(by: -KTVLyricBrowse.pointsPerLine * 500, playing: 20, lineCount: 60)
        #expect(late.line == 59)
    }

    @Test("browsing continues from where it is, not from where the song is")
    func furtherScrollsMoveFromTheBrowsedLine() {
        var browse = KTVLyricBrowse()
        browse.scroll(by: KTVLyricBrowse.pointsPerLine * 4, playing: 30, lineCount: 60)
        #expect(browse.line == 26)
        // The song has moved on in the meantime. The column must not jump
        // back to it — that is the whole point of having been taken off it.
        browse.scroll(by: KTVLyricBrowse.pointsPerLine * 2, playing: 34, lineCount: 60)
        #expect(browse.line == 24)
    }

    @Test("stopping returns to the song and forgets the part-spent travel")
    func stoppingResets() {
        var browse = KTVLyricBrowse()
        browse.scroll(by: KTVLyricBrowse.pointsPerLine * 2 + 20, playing: 10, lineCount: 60)
        #expect(browse.line == 8)
        browse.stop()
        #expect(!browse.isBrowsing)
        #expect(browse.centre(whilePlaying: 40) == 40)
        // The 20 points left over must not count towards the next line: a
        // column that jumps a line the moment it is touched again is a column
        // that seems to move on its own.
        browse.scroll(by: 6, playing: 40, lineCount: 60)
        #expect(!browse.isBrowsing)
    }

    @Test("a key press moves exactly one line, every press")
    func steppingIsExact() {
        var browse = KTVLyricBrowse()
        // Part-spent wheel travel must not make the first press do nothing or
        // two lines at once.
        browse.scroll(by: 20, playing: 10, lineCount: 60)
        #expect(!browse.isBrowsing)
        browse.step(by: -1, playing: 10, lineCount: 60)
        #expect(browse.line == 9)
        browse.step(by: 1, playing: 10, lineCount: 60)
        #expect(browse.line == 10)
        browse.step(by: -1, playing: 40, lineCount: 60)
        #expect(browse.line == 9)
    }

    @Test("stepping stops at both ends")
    func steppingIsClamped() {
        var browse = KTVLyricBrowse()
        browse.step(by: -5, playing: 2, lineCount: 60)
        #expect(browse.line == 0)
        browse.step(by: 500, playing: 2, lineCount: 60)
        #expect(browse.line == 59)
        browse.step(by: 0, playing: 2, lineCount: 60)
        #expect(browse.line == 59)
    }

    @Test("a song with no words cannot be browsed")
    func noLinesMeansNoBrowsing() {
        var browse = KTVLyricBrowse()
        browse.scroll(by: 999, playing: nil, lineCount: 0)
        #expect(!browse.isBrowsing)
    }

    @Test("the capture seeds are written by the renderer and nobody else")
    func renderSeedsAreRendererOnly() throws {
        // Three statics exist so that the gates can photograph states a gate
        // cannot reach: a browsed column, enlarged words, a revealed
        // transport. Each says in its own documentation that only the renderer
        // assigns it, and a claim like that is worth exactly as much as the
        // check behind it — a stray assignment anywhere else would put a
        // person's stage into a state they did not ask for and could not
        // leave.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/YunAudioApp")
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for seed in ["browsedLineForRendering", "lyricScaleForRendering", "revealForRendering"]
        {
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                // Declarations are not assignments: `static var x = false`
                // contains the same text and is the thing being declared.
                let assignments =
                    source.ranges(of: "\(seed) = ").count
                    - source.ranges(of: "var \(seed) = ").count
                guard assignments > 0 else { continue }
                #expect(
                    file.lastPathComponent == "PanelRenderer.swift",
                    Comment(rawValue: "\(seed) is assigned in \(file.lastPathComponent)"))
            }
        }
    }

    @Test("a wheel that reports nothing sensible is ignored")
    func nonFiniteTravelIsIgnored() {
        var browse = KTVLyricBrowse()
        browse.scroll(by: .nan, playing: 5, lineCount: 60)
        browse.scroll(by: .infinity, playing: 5, lineCount: 60)
        #expect(!browse.isBrowsing)
    }
}

/// A wheel mouse against a trackpad.
///
/// `scrollingDeltaY` is points on a precise device and *lines* on a wheel — one
/// to three a notch. Measured against a 24-point line that is about a dozen
/// notches to move the column once, which is what "the wheel almost does not
/// work" was.
@Suite("the wheel moves the column")
struct KTVLyricWheelTests {

    @Test("one notch of a wheel mouse moves at least one line")
    func aNotchIsALine() {
        var browse = KTVLyricBrowse()
        // What AppKit reports for a single detent on an ordinary mouse.
        browse.scroll(by: -1, playing: 10, lineCount: 60, precise: false)
        #expect(browse.isBrowsing, "one notch did nothing")
        #expect(browse.line != nil)
        #expect(browse.line != 10)
    }

    @Test("and three notches travel three times as far")
    func notchesAccumulate() {
        var one = KTVLyricBrowse()
        one.scroll(by: -1, playing: 10, lineCount: 60, precise: false)
        var three = KTVLyricBrowse()
        three.scroll(by: -3, playing: 10, lineCount: 60, precise: false)
        let movedByOne = abs((one.line ?? 10) - 10)
        let movedByThree = abs((three.line ?? 10) - 10)
        #expect(movedByThree > movedByOne)
    }

    @Test("a trackpad is unchanged, because it was never the broken one")
    func preciseIsUntouched() {
        var browse = KTVLyricBrowse()
        // Less than a line of travel: a glide that small must not jump.
        browse.scroll(by: -10, playing: 10, lineCount: 60, precise: true)
        #expect(!browse.isBrowsing)
        browse.scroll(by: -20, playing: 10, lineCount: 60, precise: true)
        #expect(browse.isBrowsing)
    }

    @Test("and neither device can leave the song")
    func staysInsideTheSong() {
        var browse = KTVLyricBrowse()
        for _ in 0..<200 { browse.scroll(by: -5, playing: 0, lineCount: 12, precise: false) }
        #expect((browse.line ?? 0) <= 11)
        for _ in 0..<200 { browse.scroll(by: 5, playing: 0, lineCount: 12, precise: false) }
        #expect((browse.line ?? 0) >= 0)
    }
}
