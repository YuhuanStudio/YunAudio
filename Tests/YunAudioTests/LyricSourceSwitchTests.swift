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

    @Test("structural lint clears the previous song before adopting the next one")
    func adoptingATrackClearsTheAnswers() throws {
        let source = try model
        let adopt = try #require(source.range(of: "private func adopt(_ track:"))
        let end = try #require(
            source.range(
                of: "private func adoptNowPlayingResources(",
                range: adopt.upperBound..<source.endIndex))
        let body = source[adopt.lowerBound..<end.lowerBound]
        // This is wiring lint, not behavioural evidence: the executable lyric
        // worker tests own generation and late-publication acceptance.
        let answers = try #require(body.range(of: "lyricAnswers = []"))
        let alternatives = try #require(body.range(of: "lyricAlternatives = []"))
        let sourceReset = try #require(body.range(of: "lyricSource = nil"))
        let track = try #require(body.range(of: "nowPlaying = track"))
        #expect(answers.lowerBound < alternatives.lowerBound)
        #expect(alternatives.lowerBound < sourceReset.lowerBound)
        #expect(sourceReset.lowerBound < track.lowerBound)
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
            source.contains("self.lyricsSourceName = Self.lyricsSourceName(for: chosen.source)")
        )
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
        // The controls moved out of the stage and into one construction shared
        // with the panel, which is the point of them: both presentations of one
        // song must offer the same things. Scanning the stage for them would now
        // fail on the change that made them identical.
        let controls = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/KTVWordsControls.swift"), encoding: .utf8)

        #expect(controls.contains("if model.lyricAlternatives.count > 1"))
        #expect(controls.contains("model.useNextLyricSource()"))

        // And both sides really do take it, which is the invariant worth
        // holding: a control added to one and not the other is the drift this
        // replaced.
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            let source = try String(
                contentsOf: repository.appendingPathComponent(
                    "Sources/YunAudioApp/\(file)"), encoding: .utf8)
            #expect(source.contains("KTVWordsControls(model: model"), "\(file)")
        }
    }
}
