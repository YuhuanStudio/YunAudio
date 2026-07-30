import Testing

@testable import YunAudioApp

@Suite("Wrapped lyric progress")
struct SequentialTextFillTests {
    @Test("a second visual line stays dark until the first is complete")
    func fillsRowsInReadingOrder() {
        #expect(
            SequentialLineFill.widths(lineWidths: [100, 150], progress: 0.4)
                == [100, 0])
        #expect(
            SequentialLineFill.widths(lineWidths: [100, 150], progress: 0.6)
                == [100, 50])
    }

    @Test("invalid progress and widths cannot escape the laid-out text")
    func clampsInputs() {
        #expect(
            SequentialLineFill.widths(lineWidths: [100, 150], progress: -1)
                == [0, 0])
        #expect(
            SequentialLineFill.widths(lineWidths: [100, .infinity, -8], progress: 2)
                == [100, 0, 0])
    }
}
