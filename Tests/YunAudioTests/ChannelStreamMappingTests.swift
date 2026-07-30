import Testing

@testable import YunAudioEngine

@Suite("Aggregate stream channel mapping")
struct ChannelStreamMappingTests {
    @Test("one member may span several stream buffers")
    func mapsSplitStreams() throws {
        let map = RoutingEngine.map(
            streamLayouts: [
                .init(buffer: 0, startingChannel: 1, channelCount: 2),
                .init(buffer: 1, startingChannel: 3, channelCount: 2),
            ],
            orderedUIDs: ["interface"],
            channelCount: { _ in 4 })

        try expect(map, uid: "interface", channel: 0, buffer: 0, offset: 0)
        try expect(map, uid: "interface", channel: 1, buffer: 0, offset: 1)
        try expect(map, uid: "interface", channel: 2, buffer: 1, offset: 0)
        try expect(map, uid: "interface", channel: 3, buffer: 1, offset: 1)
    }

    @Test("a gap in aggregate channel numbers does not consume a logical channel")
    func skipsStartingChannelGaps() throws {
        let map = RoutingEngine.map(
            streamLayouts: [
                .init(buffer: 0, startingChannel: 1, channelCount: 2),
                .init(buffer: 1, startingChannel: 5, channelCount: 2),
            ],
            orderedUIDs: ["microphone", "application"],
            channelCount: { _ in 2 })

        try expect(map, uid: "microphone", channel: 0, buffer: 0, offset: 0)
        try expect(map, uid: "microphone", channel: 1, buffer: 0, offset: 1)
        try expect(map, uid: "application", channel: 0, buffer: 1, offset: 0)
        try expect(map, uid: "application", channel: 1, buffer: 1, offset: 1)
    }

    @Test("stream array order cannot swap channels")
    func honoursStartingChannelWhenStreamsAreOutOfOrder() throws {
        let map = RoutingEngine.map(
            streamLayouts: [
                .init(buffer: 0, startingChannel: 5, channelCount: 2),
                .init(buffer: 1, startingChannel: 1, channelCount: 2),
            ],
            orderedUIDs: ["first", "second"],
            channelCount: { _ in 2 })

        try expect(map, uid: "first", channel: 0, buffer: 1, offset: 0)
        try expect(map, uid: "first", channel: 1, buffer: 1, offset: 1)
        try expect(map, uid: "second", channel: 0, buffer: 0, offset: 0)
        try expect(map, uid: "second", channel: 1, buffer: 0, offset: 1)
    }

    @Test("invalid and empty streams never create phantom channels")
    func ignoresInvalidLayouts() throws {
        let map = RoutingEngine.map(
            streamLayouts: [
                .init(buffer: 0, startingChannel: 0, channelCount: 2),
                .init(buffer: 1, startingChannel: 1, channelCount: 0),
                .init(buffer: 2, startingChannel: 3, channelCount: 1),
            ],
            orderedUIDs: ["source"],
            channelCount: { _ in 3 })

        try expect(map, uid: "source", channel: 0, buffer: 2, offset: 0)
        #expect(map[ChannelRef(deviceUID: "source", channel: 1)] == nil)
        #expect(map[ChannelRef(deviceUID: "source", channel: 2)] == nil)
    }

    private func expect(
        _ map: [ChannelRef: (buffer: Int32, channel: Int32)],
        uid: String,
        channel: Int,
        buffer: Int32,
        offset: Int32
    ) throws {
        let point = try #require(map[ChannelRef(deviceUID: uid, channel: channel)])
        #expect(point.buffer == buffer)
        #expect(point.channel == offset)
    }
}
