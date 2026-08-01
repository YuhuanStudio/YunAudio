import Foundation
import Testing

@testable import YunAudioApp

/// The two presentations of one song must offer the same things.
///
/// They drifted for months and nothing noticed, because nothing could: the stage
/// grew a transport, a key, 原唱／伴奏, a script switch and a queue while the
/// panel grew a scoring readout, file pickers and a lyric source — each in its
/// own file, each perfectly correct on its own. What was missing was anything
/// that could see both at once.
///
/// This is that. It reads the two files and asks whether the shared
/// constructions are in both, which is the only definition of parity that does
/// not rot: a control added to a shared component reaches both by construction,
/// and a control added to one file only fails here.
@Suite("the stage and the panel offer the same things")
struct StageAndPanelParityTests {

    private func source(_ name: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent("Sources/YunAudioApp/\(name)"),
            encoding: .utf8)
    }

    @Test("both take the shared words controls")
    func wordsControls() throws {
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            #expect(try source(file).contains("KTVWordsControls(model: model"), "\(file)")
        }
    }

    @Test("both take the shared transport")
    func transport() throws {
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            #expect(try source(file).contains("KTVTransportBar("), "\(file)")
        }
    }

    @Test("both can be handed a song and a lyric file")
    func filePickers() throws {
        // The stage reaches these through the queue popover it now carries; the
        // panel has them in its own row. Different layouts, one action — which
        // is the rule: "open a song" cannot mean two things.
        let stage =
            try source("KTVWindow.swift") + (try source("KTVQueueList.swift"))
            + (try source("KTVWordsSourcing.swift"))
        let panel = try source("SingingPanel.swift") + (try source("KTVWordsSourcing.swift"))
        for surface in [stage, panel] {
            #expect(surface.contains("KTVFilePickers.chooseSongs"))
            #expect(surface.contains("KTVFilePickers.chooseWords"))
        }
    }

    @Test("both offer the scoring switch, the note and the key suggestion")
    func scoring() throws {
        // The surface people actually sing at could not turn scoring on, see
        // the note it was hearing, or act on the key it suggested — all of it
        // lived in the column behind the window.
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            #expect(try source(file).contains("KTVScoringControls(model: model"), "\(file)")
        }
    }

    @Test("both say where the words came from, and why there are none")
    func provenance() throws {
        // The stage showed a bare source name: not whether the timing came from
        // the file, not which catalogue answered, not the copyright the index
        // asks to be shown, and — the one that matters when the stage is empty
        // — not a line about why.
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            #expect(try source(file).contains("KTVLyricsProvenance(model: model"), "\(file)")
        }
    }

    @Test("and the queue is reachable from the stage")
    func queue() throws {
        #expect(try source("KTVWindow.swift").contains("KTVQueueList(model: model"))
    }

    @Test("both warn that voice isolation is about to delete the song")
    func voiceIsolation() throws {
        // The setting behind "everything sounds wrong": Apple's model keeps one
        // person speaking and treats the backing track — and a held note — as
        // the noise it exists to remove. The panel warned about it. The stage,
        // which fills the screen and hides the panel behind it, did not.
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            #expect(
                try source(file).contains("KTVVoiceIsolationNotice(model: model"), "\(file)")
        }
    }

    @Test("both can go looking for words that did not resolve by themselves")
    func wordsSourcing() throws {
        // Searching the lyric sources by title, driving a set of words by hand,
        // and going back to the player. The stage could open a file and nothing
        // else — so 「慢冷」, whose automatic match returns a different edition,
        // could not be repaired from the window it looks wrong in.
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            #expect(try source(file).contains("KTVWordsSourcing(model: model"), "\(file)")
        }
    }

    @Test("the key is read out once, in one place, with its confidence")
    func oneKeyReadout() throws {
        // Both had one. They disagreed about the wording — "The song is in" and
        // "This song is in %@" — and about how far it should move, and only one
        // of them admitted when the detection was a guess. Two controls doing
        // one job in the same column is worse than either alone.
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            let text = try source(file)
            #expect(!text.contains("model.applySuggestedShift()"), "\(file)")
            #expect(!text.contains("loc(\"The song is in\")"), "\(file)")
        }
        let shared = try source("KTVScoringControls.swift")
        #expect(shared.contains("model.applySuggestedShift()"))
        // And the honesty travelled with it rather than being left behind.
        #expect(shared.contains("songKey.confidence <= Self.aGuessBelow"))
        #expect(shared.contains("loc(\"a guess\")"))
    }

    @Test("neither builds its own copy of a shared control")
    func noPrivateCopies() throws {
        // The shape the drift took: a row written into one file, and months
        // later a second, different row written into the other. Naming the
        // symbols that must live in exactly one place is what stops it.
        for file in ["KTVWindow.swift", "SingingPanel.swift"] {
            let text = try source(file)
            #expect(!text.contains("model.showsRomanisation.toggle()"), "\(file)")
            // Not `nudgeLyricOffset` itself: the stage answers a keyboard
            // shortcut with it, which is a second *route to* the one control
            // rather than a second copy of it. What must not exist twice is the
            // button.
            #expect(!text.contains("model.useNextLyricSource()"), "\(file)")
        }
    }
}
