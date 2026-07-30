import Foundation
import Testing
import YunAudioRT

@testable import YunAudioApp
@testable import YunAudioEngine

/// Most tuner polls neither rescore nor cross a semitone.
///
/// This benchmark keeps the current dictionary-and-array rebuild beside the
/// row-order COW candidate. The candidate earns a production fast path only if
/// Release proves that unchanged rows retain their storage.
@MainActor
@Suite("Singer refresh steady-state performance", .serialized)
struct SingerRefreshSteadyStatePerformanceTests {
    #if DEBUG
        @Test(
            "same-note polls retain singer row storage",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("same-note polls retain singer row storage")
    #endif
    func sameNotePolls() {
        let singers = [
            RouterModel.Singer(
                uid: "microphone-a", name: "Alto", hertz: 220, score: .none),
            RouterModel.Singer(
                uid: "microphone-b", name: "Tenor", hertz: 330, score: .none),
            RouterModel.Singer(
                uid: "microphone-c", name: "Soprano", hertz: 440, score: .none),
            RouterModel.Singer(
                uid: "microphone-d", name: "Bass", hertz: 110, score: .none),
        ]
        let uids = singers.map(\.uid)
        let measured = singers.map { $0.hertz * 1.001 }
        let iterations = 10_000

        _ = Self.legacyMany(
            singers: singers, uids: uids, measured: measured, iterations: 1)
        _ = Self.indexedMany(
            singers: singers, uids: uids, measured: measured, iterations: 1)
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let legacy = Self.measureLegacy(
            singers: singers, uids: uids, measured: measured, iterations: iterations)
        let indexed = Self.measureIndexed(
            singers: singers, uids: uids, measured: measured, iterations: iterations)

        print(
            "\(iterations) same-note singer polls: legacy \(legacy.nanoseconds) ns / "
                + "\(legacy.allocations) allocations; indexed \(indexed.nanoseconds) ns / "
                + "\(indexed.allocations) allocations")
        #expect(legacy.checksum == indexed.checksum)
        #expect(legacy.allocations > indexed.allocations)
        #expect(indexed.allocations == 0)
        #expect(legacy.nanoseconds > indexed.nanoseconds * 2)
    }

    private static func measureLegacy(
        singers: [RouterModel.Singer], uids: [String], measured: [Float],
        iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        let checksum = legacyMany(
            singers: singers, uids: uids, measured: measured, iterations: iterations)
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    private static func measureIndexed(
        singers: [RouterModel.Singer], uids: [String], measured: [Float],
        iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        let checksum = indexedMany(
            singers: singers, uids: uids, measured: measured, iterations: iterations)
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    @inline(never)
    private static func legacyMany(
        singers: [RouterModel.Singer], uids: [String], measured: [Float],
        iterations: Int
    ) -> Int {
        var checksum = 0
        for _ in 0..<iterations {
            let previous = Dictionary(
                uniqueKeysWithValues: singers.map { ($0.uid, $0) })
            var updated: [RouterModel.Singer] = []
            for index in uids.indices {
                let uid = uids[index]
                guard let held = previous[uid] else { continue }
                updated.append(
                    RouterModel.Singer(
                        uid: uid,
                        name: held.name,
                        hertz: RouterModel.singerDisplayHertz(
                            measured: measured[index],
                            previous: held,
                            rescore: false),
                        score: held.score))
            }
            checksum &+= Self.consume(updated)
        }
        return checksum
    }

    @inline(never)
    private static func indexedMany(
        singers: [RouterModel.Singer], uids: [String], measured: [Float],
        iterations: Int
    ) -> Int {
        var checksum = 0
        for _ in 0..<iterations {
            var updated = singers
            var changed = false
            for index in uids.indices {
                guard index < singers.count, singers[index].uid == uids[index]
                else { continue }
                let held = singers[index]
                let hertz = RouterModel.singerDisplayHertz(
                    measured: measured[index],
                    previous: held,
                    rescore: false)
                if hertz != held.hertz {
                    updated[index] = RouterModel.Singer(
                        uid: held.uid, name: held.name, hertz: hertz,
                        score: held.score)
                    changed = true
                }
            }
            checksum &+= Self.consume(changed ? updated : singers)
        }
        return checksum
    }

    @inline(never)
    private static func consume(_ singers: [RouterModel.Singer]) -> Int {
        singers.reduce(into: 0) {
            $0 &+= $1.uid.utf8.count
            $0 &+= Int($1.hertz * 1_000)
            $0 &+= Int($1.score.percentage)
        }
    }
}
