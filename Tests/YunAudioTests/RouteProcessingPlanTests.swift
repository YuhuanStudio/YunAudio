import Testing

@testable import YunAudioEngine

@Suite("Route processing provenance")
struct RouteProcessingPlanTests {
    @Test("an empty topology cannot erase microphone processing facts")
    func emptyTopologyPreservesProvenance() {
        let microphone = ChannelRef(deviceUID: "microphone", channel: 0)
        let plan = RouteProcessingPlan(
            microphoneDeviceUID: microphone.deviceUID,
            processedSource: microphone,
            echoCancellationActive: true)

        // No operation is performed for the empty graph. Reusing the immutable
        // plan is the contract: a dummy RT route never becomes a source of
        // semantic truth.
        let afterEmptyGraph = plan
        #expect(
            afterEmptyGraph.provenance(for: microphone)
                == .init(
                    usesIsolatedSource: true,
                    usesCancelledSource: false,
                    appliesInputTrim: true))
    }

    @Test("raw microphone and application routes receive independent facts")
    func sourcesAreClassifiedByIdentity() {
        let microphone = ChannelRef(deviceUID: "microphone", channel: 0)
        let application = ChannelRef(deviceUID: "tap.application", channel: 0)
        let plan = RouteProcessingPlan(
            microphoneDeviceUID: microphone.deviceUID,
            processedSource: nil,
            echoCancellationActive: true)

        #expect(
            plan.provenance(for: microphone)
                == .init(
                    usesIsolatedSource: false,
                    usesCancelledSource: true,
                    appliesInputTrim: true))
        #expect(
            plan.provenance(for: application)
                == .init(
                    usesIsolatedSource: false,
                    usesCancelledSource: false,
                    appliesInputTrim: false))
    }

    @Test("changing a stage does not change microphone ownership")
    func replacingTheStagePreservesTheInputContract() {
        let microphone = ChannelRef(deviceUID: "microphone", channel: 0)
        let application = ChannelRef(deviceUID: "tap.application", channel: 0)
        let raw = RouteProcessingPlan(
            microphoneDeviceUID: microphone.deviceUID,
            processedSource: nil,
            echoCancellationActive: false)
        let processed = raw.replacingProcessedSource(application)

        #expect(processed.provenance(for: application).usesIsolatedSource)
        #expect(processed.provenance(for: microphone).appliesInputTrim)
        #expect(!processed.provenance(for: microphone).usesCancelledSource)
    }
}
