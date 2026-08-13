import Testing

@testable import YunAudioHAL

@Suite("Audio value descriptions")
struct AudioValueDescriptionTests {
    @Test("ordinary rates keep their whole-number spelling")
    func ordinaryRate() {
        #expect(audioIntegerDescription(48_000) == "48000")
        #expect(audioIntegerDescription(44_100.75) == "44100")
    }

    @Test("non-finite and out-of-range values are printable rather than trapping")
    func invalidRate() {
        #expect(audioIntegerDescription(.nan).lowercased().contains("nan"))
        #expect(audioIntegerDescription(.infinity).lowercased().contains("inf"))
        #expect(audioIntegerDescription(-.infinity).lowercased().contains("inf"))
        #expect(!audioIntegerDescription(.greatestFiniteMagnitude).isEmpty)
        #expect(!audioIntegerDescription(-.greatestFiniteMagnitude).isEmpty)
    }
}
