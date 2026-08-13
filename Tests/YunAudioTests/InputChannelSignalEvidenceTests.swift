import Foundation
import Testing
@testable import YunAudioHAL

@Suite("Direct input-channel evidence")
struct InputChannelSignalEvidenceTests {
    @Test("fixed windows preserve exact signal and silence")
    func fixedWindowsPreserveExactSignalAndSilence() {
        let samples: [Float] = [
            0, 0, 0, 0,
            0.5, -0.5, 0, 0,
            .nan, .infinity, 0.25, -0.25,
            0, 0, 0, 0,
            0, 0,
        ]

        let windows = InputChannelSignalEvidence.windows(
            samples: samples, windowFrames: 4)

        #expect(windows.count == 5)
        #expect(windows[0].isExactlySilent)
        #expect(windows[1].peak == 0.5)
        #expect(abs(windows[1].rms - 0.353_553_38) < 0.000_001)
        #expect(windows[1].activeFrames == 2)
        #expect(windows[2].peak == 0.25)
        #expect(windows[2].activeFrames == 2)
        #expect(windows[3].isExactlySilent)
        #expect(windows[4].frameCount == 2)
        #expect(windows[4].isExactlySilent)
        #expect(InputChannelSignalEvidence.longestSilentRunAfterSignal(windows) == 2)
    }

    @Test("leading silence is not mistaken for a dropout")
    func leadingSilenceIsNotMistakenForDropout() {
        let windows = InputChannelSignalEvidence.windows(
            samples: [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0],
            windowFrames: 2)

        #expect(InputChannelSignalEvidence.longestSilentRunAfterSignal(windows) == 3)
    }
}
