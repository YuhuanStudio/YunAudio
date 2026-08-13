import Foundation
import Testing

@testable import YunAudioApp

@Suite("Capture-tap capacity")
struct CaptureTapCapacityTests {
    @Test("hardware and taps share one sixteen-endpoint aggregate budget")
    func endpointBudget() {
        #expect(RouterModel.captureTapCapacity(hardwareEndpointUIDs: []) == 16)
        #expect(
            RouterModel.captureTapCapacity(
                hardwareEndpointUIDs: ["source", "destination"]) == 14)
        #expect(
            RouterModel.captureTapCapacity(
                hardwareEndpointUIDs: ["source", "destination", "monitor"]) == 13)
        #expect(
            RouterModel.captureTapCapacity(
                hardwareEndpointUIDs: (0..<16).map { "device-\($0)" }) == 0)
        #expect(
            RouterModel.captureTapCapacity(
                hardwareEndpointUIDs: (0..<17).map { "device-\($0)" }) == 0)
    }

    @Test("duplicate roles consume one physical endpoint")
    func duplicates() {
        #expect(
            RouterModel.captureTapCapacity(
                hardwareEndpointUIDs: ["duplex", "duplex", "monitor", "monitor"])
                == 14)
    }

    @Test("all invalid values are refused before the sole process-tap constructor")
    func completePreflightPrecedesTapCreation() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let worker = try #require(source.range(of: "private func beginStartOnEngineQueue"))
        let finish = try #require(
            source.range(
                of: "private func finishCancelledStart",
                range: worker.upperBound..<source.endIndex))
        let workerBody = source[worker.lowerBound..<finish.lowerBound]
        let admission = try #require(
            workerBody.range(of: "try RoutingEngine.validateStartPreflight("))
        let preparation = try #require(
            workerBody.range(of: "let preparation = Self.prepareCapture("))
        let engineStart = try #require(workerBody.range(of: "try engine.start("))

        // Resolution runs before this closure is invoked, whereas its source
        // appears after the closure body. The enforceable ownership boundary is
        // that the complete value preflight precedes the sole constructor.
        #expect(admission.lowerBound < preparation.lowerBound)
        #expect(preparation.lowerBound < engineStart.lowerBound)
        let beforePreparation = workerBody[workerBody.startIndex..<preparation.lowerBound]
        #expect(beforePreparation.ranges(of: "ProcessTap(").isEmpty)

        let creator = try #require(
            source.range(of: "nonisolated private static func prepareCapture("))
        let creatorEnd = try #require(
            source.range(
                of: "/// Every input in the route",
                range: creator.upperBound..<source.endIndex))
        let creatorBody = source[creator.lowerBound..<creatorEnd.lowerBound]
        #expect(creatorBody.ranges(of: "ProcessTap(").count == 1)
        #expect(creatorBody.contains("refused.append"))

        let resolver = try #require(
            source.range(of: "nonisolated private static func resolveCapture("))
        let resolverBody = source[resolver.lowerBound..<creator.lowerBound]
        #expect(resolverBody.ranges(of: "AudioApplications.grouped").count == 1)
        #expect(resolverBody.ranges(of: "ProcessTap(").isEmpty)
        #expect(resolverBody.contains("unresolved:"))
    }

    @Test("durable incident admission strictly precedes the first process tap")
    func incidentCheckpointPrecedesOwnership() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let worker = try #require(source.range(of: "private func beginStartOnEngineQueue"))
        let finish = try #require(
            source.range(
                of: "private func finishCancelledStart",
                range: worker.upperBound..<source.endIndex))
        let body = source[worker.lowerBound..<finish.lowerBound]

        let reserve = try #require(
            body.range(of: "engine.reserveAudioIncidentBeforeOwnership("))
        let initialWait = try #require(
            body.range(of: "switch initialReceipt.wait(timeout: .seconds(1))"))
        let boundary = try #require(
            body.range(of: "engine.makeProcessTapOwnershipCheckpoint("))
        let initialPersisted = try #require(
            body.range(
                of: "case .persisted:",
                range: initialWait.lowerBound..<boundary.lowerBound))
        let boundaryReceipt = try #require(
            body.range(of: "ownershipReceipt.wait(timeout: .seconds(1)) == .persisted"))
        let begin = try #require(body.range(of: "engine.beginAudioIncidentOwnership("))
        let prepare = try #require(body.range(of: "let preparation = Self.prepareCapture("))

        #expect(reserve.lowerBound < initialWait.lowerBound)
        #expect(initialWait.lowerBound < initialPersisted.lowerBound)
        #expect(initialPersisted.lowerBound < boundary.lowerBound)
        #expect(boundary.lowerBound < boundaryReceipt.lowerBound)
        #expect(boundaryReceipt.lowerBound < begin.lowerBound)
        #expect(begin.lowerBound < prepare.lowerBound)

        let creator = try #require(
            source.range(of: "nonisolated private static func prepareCapture("))
        let creatorEnd = try #require(
            source.range(
                of: "/// Every input in the route",
                range: creator.upperBound..<source.endIndex))
        let creatorBody = source[creator.lowerBound..<creatorEnd.lowerBound]
        let constructed = try #require(creatorBody.range(of: "tap = try ProcessTap("))
        let adopted = try #require(creatorBody.range(of: "didCreateTap(tap)"))
        let retained = try #require(creatorBody.range(of: "taps.append(tap)"))
        let formatRead = try #require(creatorBody.range(of: "tap.format?"))
        #expect(constructed.lowerBound < adopted.lowerBound)
        #expect(adopted.lowerBound < retained.lowerBound)
        #expect(adopted.lowerBound < formatRead.lowerBound)
    }
}
