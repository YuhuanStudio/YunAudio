import CoreAudio
import Testing

@testable import YunAudioEngine

@Suite("Route-start capacity")
struct RouteStartCapacityTests {
    private func request(
        routes: [Route] = [], tapUIDs: [String] = [],
        additionalSourceUIDs: [String] = [],
        additionalDestinationUIDs: [String] = [],
        monitorDeviceUID: String? = nil,
        effects: [EffectKind] = [], plugins: [AudioUnitPlugin] = [],
        voiceIsolation: VoiceIsolationSettings? = nil,
        echoCancellation: EchoCancellationSettings? = nil,
        outputLatencyTrim: [String: Int] = [:]
    ) -> RoutingEngine.StartResourceRequest {
        .init(
            sourceDeviceUID: "source", destinationDeviceUID: "destination",
            routes: routes, tapUIDs: tapUIDs,
            additionalSourceUIDs: additionalSourceUIDs,
            additionalDestinationUIDs: additionalDestinationUIDs,
            monitorDeviceUID: monitorDeviceUID, effects: effects,
            plugins: plugins, voiceIsolation: voiceIsolation,
            echoCancellation: echoCancellation,
            outputLatencyTrim: outputLatencyTrim)
    }

    private func plugin(_ index: Int) -> AudioUnitPlugin {
        .init(
            type: 1, subType: OSType(index + 1), manufacturer: 2,
            name: "plugin-\(index)", manufacturerName: "maker",
            loadsInProcess: true)
    }

    private func capture(
        _ index: Int, processIDs: [AudioObjectID]? = nil
    ) -> RoutingEngine.ProcessTapPreflightIdentity {
        .init(
            bundleID: "capture-\(index)",
            processIDs: processIDs ?? [AudioObjectID(index + 1)])
    }

    private func preflight(
        baseRoutes: [Route] = [],
        sources: [String] = ["source"],
        captures: [RoutingEngine.ProcessTapPreflightIdentity] = [],
        destinations: [RoutingEngine.DestinationPreflight] = [
            .init(uid: "destination", outputChannels: 2)
        ],
        additionalSourceUIDs: [String] = [],
        additionalDestinationUIDs: [String] = [],
        monitorDeviceUID: String? = nil,
        monitorOutputChannels: Int? = nil,
        effects: [EffectKind] = [],
        plugins: [AudioUnitPlugin] = [],
        preferredSampleRate: Double? = nil,
        bufferFrames: UInt32 = 128,
        voiceIsolation: VoiceIsolationSettings? = nil,
        echoCancellation: EchoCancellationSettings? = nil,
        outputLatencyTrim: [String: Int] = [:]
    ) -> RoutingEngine.StartPreflightRequest {
        .init(
            sourceDeviceUID: "source",
            destinationDeviceUID: "destination",
            baseRoutes: baseRoutes,
            sources: sources,
            captures: captures,
            destinations: destinations,
            additionalSourceUIDs: additionalSourceUIDs,
            additionalDestinationUIDs: additionalDestinationUIDs,
            monitorDeviceUID: monitorDeviceUID,
            monitorOutputChannels: monitorOutputChannels,
            effects: effects,
            plugins: plugins,
            preferredSampleRate: preferredSampleRate,
            bufferFrames: bufferFrames,
            voiceIsolation: voiceIsolation,
            echoCancellation: echoCancellation,
            outputLatencyTrim: outputLatencyTrim)
    }

    @Test("sixteen aggregate endpoints are admitted before HAL and seventeen are refused")
    func aggregateEndpoints() throws {
        try RoutingEngine.validateStartResources(
            request(tapUIDs: (0..<14).map { "tap-\($0)" }))

        do {
            try RoutingEngine.validateStartResources(
                request(tapUIDs: (0..<15).map { "tap-\($0)" }))
            Issue.record("seventeen aggregate endpoints were admitted")
        } catch let RoutingError.startResourceExceedsLimit(resource, requested, maximum) {
            #expect(resource == "aggregate endpoints")
            #expect(requested == 17)
            #expect(maximum == 16)
        }
    }

    @Test("resolved captures share the endpoint budget before any tap exists")
    func resolvedCaptureEndpoints() throws {
        try RoutingEngine.validateStartPreflight(
            preflight(captures: (0..<14).map { capture($0) }))

        do {
            try RoutingEngine.validateStartPreflight(
                preflight(captures: (0..<15).map { capture($0) }))
            Issue.record("seventeen projected aggregate endpoints were admitted")
        } catch let RoutingError.startResourceExceedsLimit(resource, requested, maximum) {
            #expect(resource == "aggregate endpoints")
            #expect(requested == 17)
            #expect(maximum == 16)
        }
    }

    @Test("base, tap and monitor routes share the exact sixty-four-route budget")
    func projectedRouteFormula() throws {
        let sourceUIDs = ["source", "source-1"]
        let destinationUIDs = ["destination", "destination-1", "destination-2"]
        let baseRoutes = sourceUIDs.flatMap { source in
            destinationUIDs.flatMap { destination in
                (0..<2).map { channel in
                    Route(
                        source: .init(deviceUID: source, channel: channel),
                        destination: .init(deviceUID: destination, channel: channel))
                }
            }
        }
        let destinations = destinationUIDs.map {
            RoutingEngine.DestinationPreflight(uid: $0, outputChannels: 2)
        }
        let admitted = preflight(
            baseRoutes: baseRoutes,
            sources: sourceUIDs,
            captures: (0..<6).map { capture($0) },
            destinations: destinations,
            additionalSourceUIDs: ["source-1"],
            additionalDestinationUIDs: ["destination-1", "destination-2"],
            monitorDeviceUID: "monitor",
            monitorOutputChannels: 2)
        try RoutingEngine.validateStartPreflight(admitted)

        do {
            try RoutingEngine.validateStartPreflight(
                preflight(
                    baseRoutes: baseRoutes,
                    sources: sourceUIDs,
                    captures: (0..<7).map { capture($0) },
                    destinations: destinations,
                    additionalSourceUIDs: ["source-1"],
                    additionalDestinationUIDs: ["destination-1", "destination-2"],
                    monitorDeviceUID: "monitor",
                    monitorOutputChannels: 2))
            Issue.record("seventy-two conservatively projected routes were admitted")
        } catch let RoutingError.startResourceExceedsLimit(resource, requested, maximum) {
            #expect(resource == "projected routes")
            #expect(requested == 72)
            #expect(maximum == 64)
        }
    }

    @Test("a source device output is a monitor, but a route destination is not")
    func monitorEndpointIdentity() throws {
        try RoutingEngine.validateStartPreflight(
            preflight(
                monitorDeviceUID: "source",
                monitorOutputChannels: 2))

        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(
                    monitorDeviceUID: "destination",
                    monitorOutputChannels: 2))
        }
    }

    @Test("capture and far-end identities share one sixty-four-process budget")
    func totalProcessIdentityBudget() throws {
        let forty = (1...40).map(AudioObjectID.init)
        let twentyFour = (100...123).map(AudioObjectID.init)
        try RoutingEngine.validateStartPreflight(
            preflight(
                captures: [capture(0, processIDs: forty)],
                echoCancellation: .init(
                    speakerUID: "speaker", farEndProcessIDs: twentyFour)))

        do {
            try RoutingEngine.validateStartPreflight(
                preflight(
                    captures: [capture(0, processIDs: forty)],
                    echoCancellation: .init(
                        speakerUID: "speaker",
                        farEndProcessIDs: twentyFour + [124])))
            Issue.record("sixty-five process-ID references were admitted")
        } catch let RoutingError.startResourceExceedsLimit(resource, requested, maximum) {
            #expect(resource == "start process IDs")
            #expect(requested == 65)
            #expect(maximum == 64)
        }
    }

    @Test("the far-end reference consumes one of the process-tap slots")
    func farEndTapBudget() {
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(
                    tapUIDs: (0..<16).map { "tap-\($0)" },
                    echoCancellation: .init(
                        speakerUID: "speaker", farEndProcessIDs: [1])))
        }
    }

    @Test("every expensive start field is admitted from values before creation")
    func completePreflightFields() {
        let routeFromUnknownSource = Route(
            source: .init(deviceUID: "unknown", channel: 0),
            destination: .init(deviceUID: "destination", channel: 0))
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(baseRoutes: [routeFromUnknownSource]))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(preflight(sources: []))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(destinations: [.init(uid: "destination", outputChannels: 0)]))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(
                    plugins: (0...RoutingEngine.maximumHostedPlugins).map { plugin($0) }))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(voiceIsolation: .init(mixPercent: .nan)))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(outputLatencyTrim: ["stale-output": 1]))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(
                    echoCancellation: .init(
                        speakerUID: "speaker", farEndProcessIDs: [0])))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(
                    captures: [
                        .init(bundleID: "capture", processIDs: [1, 1])
                    ]))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(preferredSampleRate: .nan))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartPreflight(
                preflight(bufferFrames: 4_097))
        }
    }

    @Test("plugin and device-reference work are independently bounded")
    func synchronousWorkCounts() throws {
        try RoutingEngine.validateStartResources(
            request(plugins: (0..<16).map { plugin($0) }))
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(plugins: (0..<17).map { plugin($0) }))
        }

        let references = Array(repeating: "source", count: 32)
        try RoutingEngine.validateStartResources(
            request(additionalSourceUIDs: references))
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(additionalSourceUIDs: references + ["source"]))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(effects: [.gate, .gate]))
        }
    }

    @Test("start and live swaps share exact Audio Unit admission")
    func processingAdmission() throws {
        let admitted = (0..<RoutingEngine.maximumHostedPlugins).map { plugin($0) }
        try RoutingEngine.validateProcessingResources(
            effects: [.gate], plugins: admitted,
            voiceIsolation: .init(mixPercent: 100))

        let refused = admitted + [plugin(RoutingEngine.maximumHostedPlugins)]
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateProcessingResources(
                effects: [], plugins: refused, voiceIsolation: nil)
        }

        let duplicateIdentity = AudioUnitPlugin(
            type: admitted[0].type,
            subType: admitted[0].subType,
            manufacturer: admitted[0].manufacturer,
            name: "renamed duplicate",
            manufacturerName: "another maker",
            loadsInProcess: true)
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateProcessingResources(
                effects: [], plugins: [admitted[0], duplicateIdentity],
                voiceIsolation: nil)
        }

        let remote = AudioUnitPlugin(
            type: 1, subType: 1, manufacturer: 2,
            name: "remote", manufacturerName: "maker", loadsInProcess: false)
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateProcessingResources(
                effects: [], plugins: [remote], voiceIsolation: nil)
        }

        let engine = RoutingEngine()
        #expect(!engine.updateEffects([], plugins: refused))
        guard case .invalidConfiguration = engine.lastEffectUpdateRefusal else {
            Issue.record("live swap did not report shared processing admission")
            return
        }
    }

    @Test("route numbers cannot poison the realtime graph")
    func routeValues() throws {
        let admitted = Route(
            source: .init(deviceUID: "source", channel: 63),
            destination: .init(deviceUID: "destination", channel: 63),
            gain: 1)
        try RoutingEngine.validateStartResources(request(routes: [admitted]))

        for route in [
            Route(
                source: .init(deviceUID: "source", channel: -1),
                destination: .init(deviceUID: "destination", channel: 0)),
            Route(
                source: .init(deviceUID: "source", channel: 64),
                destination: .init(deviceUID: "destination", channel: 0)),
            Route(
                source: .init(deviceUID: "source", channel: 0),
                destination: .init(deviceUID: "destination", channel: 0),
                gain: .nan),
        ] {
            #expect(throws: RoutingError.self) {
                try RoutingEngine.validateStartResources(request(routes: [route]))
            }
        }
    }

    @Test("latency and identifier endpoints are exact")
    func latencyAndIdentifiers() throws {
        try RoutingEngine.validateStartResources(
            request(outputLatencyTrim: ["destination": 48_000]))
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(outputLatencyTrim: ["destination": 48_001]))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(outputLatencyTrim: ["destination": -1]))
        }
        #expect(throws: RoutingError.self) {
            var oversized = request()
            oversized.sourceDeviceUID = String(repeating: "u", count: 1_025)
            try RoutingEngine.validateStartResources(oversized)
        }
    }

    @Test("voice and echo settings are finite and bounded")
    func processingSettings() throws {
        try RoutingEngine.validateStartResources(
            request(
                voiceIsolation: .init(mixPercent: 100),
                echoCancellation: .init(
                    speakerUID: "speaker",
                    farEndProcessIDs: (1...64).map(AudioObjectID.init))))

        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(voiceIsolation: .init(mixPercent: .nan)))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(
                    echoCancellation: .init(
                        speakerUID: "speaker",
                        farEndProcessIDs: (1...65).map(AudioObjectID.init))))
        }
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateStartResources(
                request(
                    echoCancellation: .init(
                        speakerUID: "speaker", farEndProcessIDs: [1, 1])))
        }
    }

    @Test("a slow HAL refusal cannot multiply into more retries")
    func retryBudget() {
        #expect(RoutingEngine.permitsStartRetry(elapsed: 0))
        #expect(RoutingEngine.permitsStartRetry(elapsed: 5))
        #expect(!RoutingEngine.permitsStartRetry(elapsed: 5.0.nextUp))
        #expect(!RoutingEngine.permitsStartRetry(elapsed: -1))
        #expect(!RoutingEngine.permitsStartRetry(elapsed: .nan))
        #expect(!RoutingEngine.permitsStartRetry(elapsed: .infinity))
    }
}
