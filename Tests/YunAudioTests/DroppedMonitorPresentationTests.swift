import Testing

@testable import YunAudioApp

@MainActor
@Suite("Dropped monitor presentation")
struct DroppedMonitorPresentationTests {
    @Test("a monitor refusal is product language, not a CoreAudio diagnostic")
    func messageBoundary() {
        let name = "Studio Headphones"
        let diagnostic =
            "output channel 0 of com.yuhuanstudio.yunaudio.aggregate.UUID is not part of the aggregate"
        let message = RouterModel.monitorUnavailableMessage(name)

        #expect(message.contains(name))
        #expect(message.contains("main mix"))
        #expect(!message.contains(diagnostic))
        #expect(!message.contains("channel 0"))
        #expect(!message.contains("aggregate.UUID"))
    }
}
