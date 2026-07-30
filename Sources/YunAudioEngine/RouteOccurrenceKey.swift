import Foundation

/// One route's stable control identity across a topology publication.
///
/// Two cables may connect the same channels. Without the occurrence, an
/// asynchronous fader command would collapse both onto the same route after a
/// graph reorder. The ordinal follows the same first-unclaimed rule as
/// `RoutingEngine.carriedPositions`: duplicates keep their relative order.
public struct RouteOccurrenceKey: Hashable, Sendable {
    public let source: ChannelRef
    public let destination: ChannelRef
    public let occurrence: Int

    public init(source: ChannelRef, destination: ChannelRef, occurrence: Int) {
        self.source = source
        self.destination = destination
        self.occurrence = occurrence
    }
}

extension Route {
    /// Control identities aligned one-for-one with this route list.
    ///
    /// Called only when a topology is installed. Pointer movement uses the
    /// resulting array and never rebuilds this dictionary on its hot path.
    public static func occurrenceKeys(in routes: [Route]) -> [RouteOccurrenceKey] {
        struct Endpoints: Hashable {
            let source: ChannelRef
            let destination: ChannelRef
        }

        var nextOccurrence: [Endpoints: Int] = [:]
        nextOccurrence.reserveCapacity(routes.count)
        return routes.map { route in
            let endpoints = Endpoints(
                source: route.source, destination: route.destination)
            let occurrence = nextOccurrence[endpoints, default: 0]
            nextOccurrence[endpoints] = occurrence + 1
            return RouteOccurrenceKey(
                source: route.source,
                destination: route.destination,
                occurrence: occurrence)
        }
    }
}
