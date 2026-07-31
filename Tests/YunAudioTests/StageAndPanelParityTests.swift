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
        let stage = try source("KTVWindow.swift") + (try source("KTVQueueList.swift"))
        let panel = try source("SingingPanel.swift")
        for surface in [stage, panel] {
            #expect(surface.contains("KTVFilePickers.chooseSongs"))
            #expect(surface.contains("KTVFilePickers.chooseWords"))
        }
    }

    @Test("and the queue is reachable from the stage")
    func queue() throws {
        #expect(try source("KTVWindow.swift").contains("KTVQueueList(model: model"))
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
