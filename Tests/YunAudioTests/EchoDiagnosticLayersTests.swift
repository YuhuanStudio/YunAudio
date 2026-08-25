import Foundation
import Testing

@testable import YunAudioEngine

/// The layers a route wraps around the echo canceller's construction.
///
/// Six weaker constructions all built without incident — the unit alone, the
/// unit with a route running, the whole bridge alone, the bridge after a rate
/// change, the bridge with a route running, and the bridge with the slice a
/// route actually asks for. What is left between those and the route is the
/// bounded lane, the cancellation context, and a graph admission held across
/// the whole thing, so those are separable here rather than argued about.
@Suite("The route's wrappings, separable")
struct EchoDiagnosticLayersTests {

    @Test("each layer is its own bit")
    func layersAreIndependent() {
        let all: EchoCancellationDiagnostics.Layers = [
            .lane, .graphAdmission, .constructionContext,
        ]
        #expect(all.contains(.lane))
        #expect(all.contains(.graphAdmission))
        #expect(all.contains(.constructionContext))
        #expect(!EchoCancellationDiagnostics.Layers([.lane]).contains(.graphAdmission))
        #expect(
            !EchoCancellationDiagnostics.Layers([.graphAdmission]).contains(.lane))
    }

    /// A construction that does not return is the fault being studied, so it
    /// has to be a value the caller receives rather than a hang the caller
    /// shares. The work runs on a thread this code owns for that reason.
    @Test("not returning is an outcome, not a hang")
    func notReturningIsAValue() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/EchoCancellationDiagnostics.swift",
            encoding: .utf8)
        #expect(source.contains("case didNotReturn"))
        // On its own thread, and waited for with a budget — the two halves of
        // learning that a synchronous call will not come back.
        #expect(source.contains("let thread = Thread"))
        #expect(source.contains("done.wait(timeout: .now() + budget)"))
    }

    /// The admission is taken before the lane, because that is the order the
    /// route takes them in and the order is one of the things under test.
    @Test("the admission is acquired before the lane is entered")
    func admissionPrecedesTheLane() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/EchoCancellationDiagnostics.swift",
            encoding: .utf8)
        let admission = try #require(
            source.range(of: "acquireGraphAdmissionAfterDraining"))
        let lane = try #require(
            source.range(of: "BoundedAudioUnitConstructionLane.echoCancellation.perform"))
        #expect(admission.lowerBound < lane.lowerBound)
    }
}

/// A clock master is not a follower of itself.
@Suite("The cancelling route's aggregate is coherent")
struct CancellingAggregateShapeTests {

    /// With the canceller holding the microphone, the destination is the only
    /// member left and it is also the clock master. It used to be marked
    /// drift-corrected, which asks Core Audio to correct a device against its
    /// own clock — a relationship that does not exist.
    ///
    /// Found by printing the aggregate's description while chasing a start that
    /// hangs, and worth keeping whether or not it turns out to be that: an
    /// incoherent description is a bad thing to diagnose from.
    @Test("the clock master is not marked drift-corrected")
    func clockMasterIsNotAFollower() throws {
        let source = try String(
            contentsOfFile: GraphLockDisciplineTests.enginePath, encoding: .utf8)
        let start = try #require(
            source.range(of: "let routedSubDevices: [AggregateDevice.SubDevice] ="))
        let body = source[start.lowerBound...].prefix(500)
        // The cancelling branch goes through the member-aware helper, not
        // through `follower` directly.
        #expect(body.contains("member(destination, clockMaster: destinationDeviceUID)"))
        #expect(!body.contains("? [follower(destination)]"))
    }
}
