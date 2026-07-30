import Foundation
import Testing
import YunAudioRT

@testable import YunAudioApp
@testable import YunAudioEngine

/// The singing poll checks the same source topology twenty times a second.
///
/// This benchmark keeps the current collection-materialising shape beside an
/// index-based candidate. If the optimiser already removes those temporary
/// arrays, the candidate has no reason to enter production.
@Suite("Source tap steady-state performance", .serialized)
struct SourceTapSteadyStatePerformanceTests {
    #if DEBUG
        @Test(
            "stable source identity allocates no temporary collections",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("stable source identity allocates no temporary collections")
    #endif
    func stableSourceIdentity() {
        let groups = [
            RouterModel.SourceGroup(uid: "microphone", routes: [0]),
            RouterModel.SourceGroup(uid: "spotify", routes: [1, 2]),
            RouterModel.SourceGroup(uid: "second microphone", routes: [3]),
            RouterModel.SourceGroup(uid: "browser", routes: [4, 5]),
        ]
        let cached = groups.map(\.uid)
        let iterations = 10_000

        _ = Self.legacyMany(groups: groups, cached: cached, iterations: 1)
        _ = Self.indexedMany(groups: groups, cached: cached, iterations: 1)
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let legacy = Self.measureLegacy(
            groups: groups, cached: cached, iterations: iterations)
        let indexed = Self.measureIndexed(
            groups: groups, cached: cached, iterations: iterations)

        print(
            "\(iterations) stable source checks: legacy \(legacy.nanoseconds) ns / "
                + "\(legacy.allocations) allocations; indexed \(indexed.nanoseconds) ns / "
                + "\(indexed.allocations) allocations")
        #expect(legacy.checksum == indexed.checksum)
        #expect(legacy.allocations > indexed.allocations)
        #expect(indexed.allocations == 0)
        #expect(legacy.nanoseconds > indexed.nanoseconds * 2)
    }

    private static func measureLegacy(
        groups: [RouterModel.SourceGroup], cached: [String], iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        let checksum = legacyMany(
            groups: groups, cached: cached, iterations: iterations)
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    private static func measureIndexed(
        groups: [RouterModel.SourceGroup], cached: [String], iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        let checksum = indexedMany(
            groups: groups, cached: cached, iterations: iterations)
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    @inline(never)
    private static func legacyMany(
        groups: [RouterModel.SourceGroup], cached: [String], iterations: Int
    ) -> Int {
        var checksum = 0
        for _ in 0..<iterations {
            let firstRoutes = groups.compactMap(\.routes.first)
            let wantedUIDs = groups.map(\.uid)
            guard
                let opened = Self.legacyReusableSourceTapCount(
                    isOpen: true, openedCount: groups.count,
                    openedFor: cached, wanted: wantedUIDs)
            else {
                checksum &+= firstRoutes.count + wantedUIDs.count
                continue
            }
            let openedGroups = Array(groups.prefix(opened))
            guard
                openedGroups.map(\.uid) == cached,
                openedGroups.count == groups.count
            else {
                checksum &+= openedGroups.count
                continue
            }
            checksum &+= opened
        }
        return checksum
    }

    @inline(never)
    private static func indexedMany(
        groups: [RouterModel.SourceGroup], cached: [String], iterations: Int
    ) -> Int {
        var checksum = 0
        for _ in 0..<iterations {
            guard
                RouterModel.sourceUIDsMatch(
                    groups: groups, prefixCount: groups.count, cached: cached),
                RouterModel.sourceUIDsMatch(
                    groups: groups, prefixCount: groups.count, cached: cached)
            else { continue }
            checksum &+= groups.count
        }
        return checksum
    }

    @inline(never)
    private static func legacyReusableSourceTapCount(
        isOpen: Bool, openedCount: Int, openedFor: [String], wanted: [String]
    ) -> Int? {
        guard isOpen, openedCount > 0, openedFor == wanted else { return nil }
        return openedCount
    }
}
