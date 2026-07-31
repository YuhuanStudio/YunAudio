import CoreGraphics
import Foundation
import Testing

@testable import YunAudioApp

/// How the column falls away from the line being sung.
@Suite("KTV lyric motion")
struct KTVLyricMotionTests {

    /// What the stage actually draws: up to four lines ahead, three behind.
    private let ahead = 1...4
    private let behind = -3...(-1)

    @Test("the column keeps receding all the way to the far line")
    func opacityFallsAwayInBothDirections() {
        // The defect this replaces: three cases, so everything past the second
        // line was one flat value and the fourth line ahead was exactly as
        // present as the second.
        for offset in ahead.dropLast() {
            #expect(
                KTVLyricMotion.opacity(forOffset: offset)
                    > KTVLyricMotion.opacity(forOffset: offset + 1),
                Comment(rawValue: "line \(offset) should outrank line \(offset + 1)"))
        }
        for offset in behind.dropFirst() {
            #expect(
                KTVLyricMotion.opacity(forOffset: offset)
                    > KTVLyricMotion.opacity(forOffset: offset - 1))
        }
        #expect(KTVLyricMotion.opacity(forOffset: 0) == 1)
    }

    @Test("the line about to be sung outranks the one just sung")
    func aheadIsWorthMoreThanBehind() {
        // The whole reason the ramp is asymmetrical: one of them is being read
        // next and the other has been read.
        for distance in 1...3 {
            #expect(
                KTVLyricMotion.opacity(forOffset: distance)
                    > KTVLyricMotion.opacity(forOffset: -distance))
        }
    }

    @Test("the two lines a singer is actually reading are never softened")
    func nearestLinesStaySharp() {
        for offset in [-1, 0, 1] {
            #expect(KTVLyricMotion.blurRadius(forOffset: offset, pointSize: 72) == 0)
        }
    }

    @Test("softness runs the right way, and scales with the type")
    func blurDeepensWithDistance() {
        // The old rule blurred only the second line, so on a stage drawing four
        // ahead the furthest was the crispest thing after the one being sung.
        let size: CGFloat = 40
        let radii = (2...4).map {
            KTVLyricMotion.blurRadius(forOffset: $0, pointSize: size)
        }
        #expect(radii == [1.2, 1.92, 2.56])
        #expect(zip(radii, radii.dropFirst()).allSatisfy { $0 < $1 })
        // Twice the type, twice the fade: a fixed radius is invisible on a
        // stage set for a room and heavy on a window set for a desk.
        #expect(
            KTVLyricMotion.blurRadius(forOffset: 2, pointSize: 80)
                == KTVLyricMotion.blurRadius(forOffset: 2, pointSize: 40) * 2)
    }

    @Test("rows follow the centre rather than leaving with it")
    func staggerGrowsAndIsBounded() {
        #expect(KTVLyricMotion.stagger(forOffset: 0) == 0)
        #expect(KTVLyricMotion.stagger(forOffset: 1) == KTVLyricMotion.staggerStep)
        // The same delay either way: the column is one sheet moving, not two.
        #expect(
            KTVLyricMotion.stagger(forOffset: -3) == KTVLyricMotion.stagger(forOffset: 3))
        // Bounded, because the delay is spent on top of the spring's settling
        // time — the far line arriving a fifth of a second late is flow, and
        // half a second late is lag.
        #expect(KTVLyricMotion.stagger(forOffset: 12) <= 0.12)
        // The furthest line the stage draws still arrives inside the spring's
        // own response, so the column never splits into two movements.
        #expect(KTVLyricMotion.stagger(forOffset: 4) < KTVLyricMotion.advanceResponse)
    }

    @Test("the stage takes its motion from here and keeps none of its own")
    func stageUsesTheRamps() throws {
        let ktv = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/YunAudioApp/KTVWindow.swift"),
            encoding: .utf8)
        #expect(ktv.contains("KTVLyricMotion.advance(forOffset: offset)"))
        #expect(ktv.contains("KTVLyricMotion.blurRadius("))
        // The numbers that used to live in the view. A copy left behind is a
        // ramp that stops agreeing with the one being tested here.
        #expect(!ktv.contains("abs(offset) == 2 ? 1.2 : 0"))
        #expect(!ktv.contains("dampingFraction: 0.78"))
    }
}
