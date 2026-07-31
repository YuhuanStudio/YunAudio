import Foundation
import Testing

@testable import YunAudioApp

/// Showing the words in the script somebody reads.
///
/// A catalogue answers in whichever script it holds: 網易雲 and QQ 音樂 return
/// simplified for songs a Taiwanese singer released in traditional, and an
/// `.lrc` beside the file is whatever whoever made it typed.
@Suite("the words in the script somebody reads")
struct LyricScriptTests {

    @Test("as written changes nothing at all")
    func asWrittenIsIdentity() {
        for text in ["我懷念那個你", "我怀念那个你", "Hello there", "", "ひらがな"] {
            #expect(LyricScript.asWritten.convert(text) == text)
        }
    }

    @Test("traditional and simplified convert the systematic pairs")
    func itConverts() {
        #expect(LyricScript.simplified.convert("我懷念那個你") == "我怀念那个你")
        #expect(LyricScript.traditional.convert("我怀念那个你") == "我懷念那個你")
        // The one the title matcher already documented: 妳 is a character in
        // its own right rather than a traditional form of 你, so it survives.
        #expect(LyricScript.simplified.convert("妳好").contains("妳"))
    }

    @Test("and a line with no Han characters is never transformed")
    func nonChineseIsUntouched() {
        // Not merely "comes out the same": the scan is what stops an English
        // song paying for a transform on every line of every redraw.
        #expect(!LyricScript.containsHan("Hello there"))
        #expect(!LyricScript.containsHan(""))
        #expect(!LyricScript.containsHan("ひらがな カタカナ"))
        #expect(LyricScript.containsHan("我"))
        for script in LyricScript.allCases {
            #expect(script.convert("Hello there") == "Hello there")
        }
    }

    @Test("the button cycles and comes back")
    func theButtonCycles() {
        var script = LyricScript.asWritten
        script = script.next
        #expect(script == .simplified)
        script = script.next
        #expect(script == .traditional)
        script = script.next
        #expect(script == .asWritten)
    }

    @Test("and its glyph is the state it is in, not the one it would move to")
    func theGlyphReadsForwards() {
        // A control that shows its destination is read backwards by half the
        // people who press it.
        #expect(LyricScript.simplified.mark == "简")
        #expect(LyricScript.traditional.mark == "繁")
        #expect(LyricScript.asWritten.mark == "字")
    }

    @Test("converting twice is the same as converting once")
    func itIsStable() {
        let once = LyricScript.simplified.convert("我懷念那個你我深愛的你")
        #expect(LyricScript.simplified.convert(once) == once)
    }
}
