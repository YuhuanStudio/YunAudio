import Testing
@testable import YunAudioEngine

@Suite("Route occurrence identity")
struct RouteOccurrenceKeyTests {
    private let source = ChannelRef(deviceUID: "source", channel: 0)
    private let destination = ChannelRef(deviceUID: "destination", channel: 0)

    @Test("Duplicate endpoints receive independent ordinals")
    func duplicateOrdinals() {
        let duplicate = Route(source: source, destination: destination)
        let other = Route(
            source: ChannelRef(deviceUID: "other", channel: 0),
            destination: destination)

        let keys = Route.occurrenceKeys(in: [duplicate, duplicate, other, duplicate])

        #expect(keys.map(\.occurrence) == [0, 1, 0, 2])
        #expect(Set(keys).count == 4)
    }

    @Test("Reordering endpoints does not renumber their duplicates")
    func topologyReorder() {
        let duplicate = Route(source: source, destination: destination)
        let other = Route(
            source: ChannelRef(deviceUID: "other", channel: 0),
            destination: destination)

        let before = Route.occurrenceKeys(in: [duplicate, duplicate, other, duplicate])
        let after = Route.occurrenceKeys(in: [other, duplicate, duplicate, duplicate])

        #expect(after == [before[2], before[0], before[1], before[3]])
    }

    @Test("Topology publication preserves each duplicate control independently")
    func controlsSurviveTopologyPublication() {
        var first = Route(source: source, destination: destination, gain: 0.2)
        first.isMuted = false
        var second = Route(source: source, destination: destination, gain: 0.4)
        second.isMuted = true
        let other = Route(
            source: ChannelRef(deviceUID: "other", channel: 0),
            destination: destination,
            gain: 0.8)
        var proposedFirst = first
        proposedFirst.gain = 1
        var proposedSecond = second
        proposedSecond.gain = 1

        let carried = RoutingEngine.preservingRouteControls(
            from: [first, second, other],
            to: [other, proposedFirst, proposedSecond])

        #expect(carried.map(\.gain) == [0.8, 0.2, 0.4])
        #expect(carried.map(\.isMuted) == [false, false, true])
    }

    @Test("A newly added route keeps its requested defaults")
    func newRouteDefaults() {
        let existing = Route(source: source, destination: destination, gain: 0.25)
        let added = Route(
            source: ChannelRef(deviceUID: "new", channel: 0),
            destination: destination,
            gain: 0.75,
            isMuted: true)

        let carried = RoutingEngine.preservingRouteControls(
            from: [existing], to: [existing, added])

        #expect(carried[0].gain == 0.25)
        #expect(carried[1].gain == 0.75)
        #expect(carried[1].isMuted)
    }
}
