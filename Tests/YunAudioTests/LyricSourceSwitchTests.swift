import Foundation
import Testing

@testable import YunAudioApp

/// The wiring behind the button that takes the next index's words.
///
/// `RouterModel` cannot be built in a test — it talks to CoreAudio on init —
/// so the parts of this that can only be stated in the model are asserted
/// against its source. That is weaker than running it, and it is what stops
/// the one failure mode that has no visible symptom until it is somebody's
/// wrong lyrics: the answers left behind by the song before.
@Suite("Lyric source switching")
struct LyricSourceSwitchTests {

    private var model: String {
        get throws {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: repository.appendingPathComponent(
                    "Sources/YunAudioApp/RouterModel.swift"), encoding: .utf8)
        }
    }

    @Test("a new song starts with no alternatives")
    func adoptingATrackClearsTheAnswers() throws {
        let source = try model
        let adopt = try #require(source.range(of: "private func adopt(_ track:"))
        // The first thing it does, before any await can let the button be
        // pressed against a list belonging to the song that just ended.
        let opening = source[adopt.lowerBound...].prefix(600)
        #expect(opening.contains("lyricAnswers = []"))
        #expect(opening.contains("lyricAlternatives = []"))
        #expect(opening.contains("lyricSource = nil"))
    }

    @Test("the button reads this song's answers, not the last lookup's")
    func cyclingDoesNotReachForTheGlobal() throws {
        let source = try model
        let start = try #require(source.range(of: "func useNextLyricSource()"))
        let end = try #require(
            source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]

        #expect(body.contains("lyricAnswers.first(where:"))
        // OnlineLyrics.lastAnswers belongs to whichever lookup ran last, which
        // is not necessarily this song's.
        #expect(!body.contains("OnlineLyrics.lastAnswers"))
        // The attribution has to move with the words.
        #expect(body.contains("lyricsSourceName = Self.lyricsSourceName(for: next)"))
    }

    @Test("a remembered choice renames the attribution too")
    func theAttributionFollowsTheChosenAnswer() throws {
        let source = try model
        #expect(
            source.contains("self.lyricsSourceName = Self.lyricsSourceName(for: chosen.source)"))
        #expect(source.contains("self.lyricsCopyright = chosen.providerMetadata?.copyright"))
        #expect(source.contains("self.lyricsRegion = chosen.providerMetadata?.region"))
        // And an empty remembered answer must not win over a full one.
        #expect(source.contains("alternative.parsed != nil || alternative.plain != nil"))
    }

    @Test("the control is drawn only when there is somewhere else to go")
    func theButtonHidesWithNothingToOffer() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stage = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/KTVWindow.swift"), encoding: .utf8)

        #expect(stage.contains("if model.lyricAlternatives.count > 1"))
        #expect(stage.contains("KTVNextLyricSource"))
        #expect(stage.contains("model.useNextLyricSource()"))
    }
}
