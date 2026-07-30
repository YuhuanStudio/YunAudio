import Testing

@testable import YunAudioApp

@Suite("Lyric publication performance")
struct LyricPublicationPerformanceTests {
    @Test("twenty-hertz polls publish ten interpolated progress targets")
    func progressCadence() {
        var polls = 0
        var publications = 0

        for _ in 0..<1_200 {
            polls += 1
            if RouterModel.isLyricProgressFrameDue(afterPolls: polls) {
                publications += 1
                polls = 0
            }
        }

        #expect(publications == 600)
        #expect(publications * 2 == 1_200)
        #expect(Double(RouterModel.lyricFrameEveryNPolls) / 20 == 0.1)
    }

    @Test("a line boundary bypasses the progress cadence")
    func lineChangesAreImmediate() {
        #expect(
            RouterModel.shouldPublishLyricProgress(
                periodicFrameDue: false, lineChanged: true))
        #expect(
            RouterModel.shouldPublishLyricProgress(
                periodicFrameDue: true, lineChanged: false))
        #expect(
            !RouterModel.shouldPublishLyricProgress(
                periodicFrameDue: false, lineChanged: false))
    }
}
