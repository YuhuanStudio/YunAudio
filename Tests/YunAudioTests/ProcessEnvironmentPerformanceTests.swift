import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// Process environment overrides are launch configuration, not live state.
///
/// This benchmark preserves the old dynamic lookup beside the cached shape so
/// an optimised Foundation implementation can disprove the change rather than
/// leaving an assumed optimisation in production.
@Suite("Process environment performance", .serialized)
struct ProcessEnvironmentPerformanceTests {
    @Test("the recognition poll uses the process-lifetime override")
    func recognitionPollUsesCachedOverride() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let start = try #require(
            source.range(of: "private func recognitionApplication("))
        let remainder = source[start.lowerBound...]
        let end = try #require(remainder.range(of: "\n    }\n"))
        let body = String(remainder[..<end.upperBound])

        #expect(body.contains("Self.recognisesScriptedPlayers"))
        #expect(!body.contains("ProcessInfo.processInfo.environment"))
    }

    #if DEBUG
        @Test(
            "a process-lifetime override is read once",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("a process-lifetime override is read once")
    #endif
    func processLifetimeOverrideIsCached() {
        let iterations = 100_000
        let cached = Self.dynamicValue()

        _ = Self.measureDynamic(iterations: 1)
        _ = Self.measureCached(cached, iterations: 1)
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let dynamic = Self.measureDynamic(iterations: iterations)
        let retained = Self.measureCached(cached, iterations: iterations)

        print(
            "\(iterations) environment reads: dynamic \(dynamic.nanoseconds) ns / "
                + "\(dynamic.allocations) allocations; cached \(retained.nanoseconds) ns / "
                + "\(retained.allocations) allocations")
        #expect(dynamic.checksum == retained.checksum)
        #expect(dynamic.allocations > retained.allocations)
        #expect(dynamic.nanoseconds > retained.nanoseconds * 2)
    }

    private static func measureDynamic(
        iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        var checksum = 0
        for _ in 0..<iterations {
            checksum &+= Self.consume(dynamicValue())
        }
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    private static func measureCached(
        _ value: Bool, iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        var checksum = 0
        for _ in 0..<iterations {
            checksum &+= Self.consume(value)
        }
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    @inline(never)
    private static func dynamicValue() -> Bool {
        ProcessInfo.processInfo.environment["YUNAUDIO_RECOGNISE_PLAYERS"] == "1"
    }

    @inline(never)
    private static func consume(_ value: Bool) -> Int {
        value ? 1 : 2
    }
}
