import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Audio processing admission")
struct AudioProcessingAdmissionTests {
    @Test("hardware values have one closed processing range")
    func hardwareBounds() {
        #expect(AudioProcessingContract.supports(sampleRate: 8_000))
        #expect(AudioProcessingContract.supports(sampleRate: 384_000))
        #expect(
            !AudioProcessingContract.supports(
                sampleRate: AudioProcessingContract.minimumSampleRate.nextDown))
        #expect(
            !AudioProcessingContract.supports(
                sampleRate: AudioProcessingContract.maximumSampleRate.nextUp))
        #expect(!AudioProcessingContract.supports(sampleRate: .nan))
        #expect(!AudioProcessingContract.supports(sampleRate: .infinity))

        #expect(AudioProcessingContract.supports(framesPerSlice: 1 as Int))
        #expect(AudioProcessingContract.supports(framesPerSlice: 4_096 as Int))
        #expect(!AudioProcessingContract.supports(framesPerSlice: 0 as Int))
        #expect(!AudioProcessingContract.supports(framesPerSlice: 4_097 as Int))
        #expect(!AudioProcessingContract.supports(framesPerSlice: Int.max))
        #expect(!AudioProcessingContract.supports(framesPerSlice: UInt32.max))
    }

    @Test("allocation products reject overflow")
    func checkedProducts() {
        #expect(AudioProcessingContract.checkedProduct(4_096, 2) == 8_192)
        #expect(
            AudioProcessingContract.checkedProduct(64, 4_096, 2)
                == 524_288)
        #expect(AudioProcessingContract.checkedProduct(Int.max, 2) == nil)
        #expect(AudioProcessingContract.checkedProduct(-1, 2) == nil)
    }

    @Test("requested and settled route timing use the same limits")
    func routeTimingLayers() throws {
        #expect(
            RoutingEngine.supportsRouteTimingRequest(
                preferredSampleRate: nil, bufferFrames: 1))
        #expect(
            RoutingEngine.supportsRouteTimingRequest(
                preferredSampleRate: 384_000, bufferFrames: 4_096))
        #expect(
            !RoutingEngine.supportsRouteTimingRequest(
                preferredSampleRate: 384_001, bufferFrames: 128))
        #expect(
            !RoutingEngine.supportsRouteTimingRequest(
                preferredSampleRate: 48_000, bufferFrames: 4_097))
        #expect(
            !RoutingEngine.supportsRouteTimingRequest(
                preferredSampleRate: 48_000, bufferFrames: UInt32.max))

        let lower = try #require(
            RoutingEngine.graphTiming(
                actualSampleRate: 8_000, actualBufferFrames: 1))
        #expect(lower.sampleRate == 8_000)
        #expect(lower.cycleFrames == 1)
        #expect(lower.processingCapacity == 4_096)

        let upper = try #require(
            RoutingEngine.graphTiming(
                actualSampleRate: 384_000, actualBufferFrames: 4_096))
        #expect(upper.sampleRate == 384_000)
        #expect(upper.cycleFrames == 4_096)
        #expect(upper.processingCapacity == 4_096)

        #expect(
            RoutingEngine.graphTiming(
                actualSampleRate: 7_999, actualBufferFrames: 128) == nil)
        #expect(
            RoutingEngine.graphTiming(
                actualSampleRate: 384_001, actualBufferFrames: 128) == nil)
        #expect(
            RoutingEngine.graphTiming(
                actualSampleRate: 48_000, actualBufferFrames: 0) == nil)
        #expect(
            RoutingEngine.graphTiming(
                actualSampleRate: 48_000, actualBufferFrames: 4_097) == nil)
        #expect(
            RoutingEngine.graphTiming(
                actualSampleRate: 48_000, actualBufferFrames: UInt32.max) == nil)
        #expect(
            RoutingEngine.graphTiming(
                actualSampleRate: .nan, actualBufferFrames: 128) == nil)
    }

    @Test("sample-rate planning discards unsupported advertisements")
    func sampleRatePlanning() throws {
        let plan = try #require(
            RoutingEngine.sampleRatePlan(
                sourceRates: [.nan, 8_000, 384_000, 384_001],
                destinationRates: [384_000, .infinity],
                preferredRate: 384_001,
                sourceCurrentRate: 8_000))
        #expect(plan.targetRate == 384_000)
        #expect(!plan.hasMismatch)

        #expect(
            RoutingEngine.sampleRatePlan(
                sourceRates: [.nan, 384_001],
                destinationRates: [48_000],
                preferredRate: nil,
                sourceCurrentRate: nil) == nil)
    }

    @Test("graph allocation dimensions are proven before allocation")
    func graphAllocationPlan() throws {
        let plan = try #require(
            RTGraph.allocationPlan(
                routeCount: 64, bufferFrames: 4_096,
                sampleRate: 384_000))
        #expect(plan.routeStorageCount == 64)
        #expect(plan.routeCount == 64)
        #expect(plan.routeStorageCount32 == 64)
        #expect(plan.routeCountForC == 64)
        #expect(plan.processingCapacity == 4_096)
        #expect(plan.processingCapacity32 == 4_096)
        #expect(plan.recordScratchCount == 8_192)
        #expect(plan.recordScratchCount32 == 8_192)
        #expect(plan.stemScratchCount == 524_288)
        #expect(plan.gainEnvelopeCount == 12_288)

        #expect(
            RTGraph.allocationPlan(
                routeCount: 65, bufferFrames: 128, sampleRate: 48_000) == nil)
        #expect(
            RTGraph.allocationPlan(
                routeCount: 1, bufferFrames: 0, sampleRate: 48_000) == nil)
        #expect(
            RTGraph.allocationPlan(
                routeCount: 1, bufferFrames: 4_097, sampleRate: 48_000) == nil)
        #expect(
            RTGraph.allocationPlan(
                routeCount: 1, bufferFrames: Int.max, sampleRate: 48_000) == nil)
        #expect(
            RTGraph.allocationPlan(
                routeCount: 1, bufferFrames: 128, sampleRate: .infinity) == nil)
        #expect(
            RTGraph.allocationPlan(
                routeCount: 1, bufferFrames: 128, sampleRate: 7_999) == nil)
        #expect(
            RTGraph.allocationPlan(
                routeCount: 1, bufferFrames: 128, sampleRate: 384_001) == nil)

        #expect(
            RTGraph.allocateIfSupported(
                routes: [], bufferFrames: 4_097, sampleRate: 48_000) == nil)
        #expect(
            RTGraph.allocateIfSupported(
                routes: [], bufferFrames: 128, sampleRate: 384_001) == nil)
    }

    @Test("a supported graph uses the admitted storage ceiling")
    func supportedGraphAllocation() throws {
        let graph = try #require(
            RTGraph.allocateIfSupported(
                routes: [], bufferFrames: 4_096, sampleRate: 384_000))
        defer { RTGraph.deallocate(graph) }

        #expect(graph.pointee.recordScratchCapacity == 8_192)
        #expect(graph.pointee.cancelledCapacity == 4_096)
        #expect(graph.pointee.stemCapacity == 4_096)
        #expect(graph.pointee.analysisCapacity == 4_096)
        #expect(graph.pointee.gainEnvelopeCapacity == 4_096)
    }

    @Test("the public realtime benchmark is admitted before configuration")
    func benchmarkAdmission() throws {
        let upper = try #require(
            RTBenchmark.admission(
                .init(
                    frames: 4_096, routes: 63, monitorRoutes: 1,
                    eqStages: RTGraph.maximumEQStages,
                    alignmentFrames: RTGraph.maximumAlignmentFrames,
                    master: 1),
                cycles: RTBenchmark.maximumCycles))
        #expect(upper.frames == 4_096)
        #expect(upper.routeCount == 63)
        #expect(upper.monitorRouteCount == 1)
        #expect(upper.cycles == 1_000_000)
        #expect(upper.interleavedSampleCount == 8_192)
        #expect(upper.interleavedByteCount == 32_768)
        #expect(upper.ringFrameCount == 65_536)
        #expect(upper.analysisDrainCount == 4_096)
        #expect(upper.recordDrainCount == 8_192)

        #expect(
            RTBenchmark.admission(
                .init(frames: 4_097), cycles: 1) == nil)
        #expect(
            RTBenchmark.admission(
                .init(routes: 65), cycles: 1) == nil)
        #expect(
            RTBenchmark.admission(
                .init(routes: 64, monitorRoutes: 1), cycles: 1) == nil)
        #expect(
            RTBenchmark.admission(
                .init(routes: 64, monitorRoutes: 0), cycles: 1) != nil)
        #expect(
            RTBenchmark.admission(
                .init(), cycles: RTBenchmark.maximumCycles + 1) == nil)
        #expect(RTBenchmark.admission(.init(), cycles: 0) == nil)
        #expect(
            RTBenchmark.admission(
                .init(eqStages: RTGraph.maximumEQStages + 1), cycles: 1) == nil)
        #expect(
            RTBenchmark.admission(
                .init(alignmentFrames: RTGraph.maximumAlignmentFrames + 1),
                cycles: 1) == nil)
        #expect(
            RTBenchmark.admission(
                .init(master: -.infinity), cycles: 1) == nil)
        #expect(RTBenchmark.admission(.init(master: -1), cycles: 1) == nil)
        #expect(RTBenchmark.run(.init(frames: 4_097), cycles: 1) == nil)
    }

    @Test("public analysers reject unsupported rates locally")
    func analyserAdmission() {
        let rejectedRates = [7_999.0, 384_001.0, .nan, .infinity]
        for sampleRate in rejectedRates {
            #expect(SpectrumAnalyser(sampleRate: sampleRate) == nil)
            #expect(LoudnessMeter(sampleRate: sampleRate) == nil)
            #expect(SoundClassifier(sampleRate: sampleRate) == nil)
            #expect(PitchTracker(sampleRate: sampleRate) == nil)
        }

        #expect(SpectrumAnalyser(sampleRate: 8_000) != nil)
        #expect(LoudnessMeter(sampleRate: 384_000) != nil)
        #expect(PitchTracker(sampleRate: 48_000) != nil)
        #expect(
            PitchTracker(
                sampleRate: 48_000,
                lowest: .leastNonzeroMagnitude,
                highest: 400) == nil)
        #expect(
            PitchTracker(
                sampleRate: 48_000, lowest: 60, highest: .infinity) == nil)
        #expect(LoudnessMeter.retainedArrayBytes(sampleRate: .nan) == 0)

        var loudness = LoudnessMeter(sampleRate: 48_000)!
        let spectrum = SpectrumAnalyser(sampleRate: 48_000)!
        let tracker = PitchTracker(sampleRate: 48_000)!
        let sample: [Float] = [0.5]
        sample.withUnsafeBufferPointer {
            loudness.add($0.baseAddress!, count: -1)
            spectrum.add($0.baseAddress!, count: -1)
        }
        #expect(loudness.peak == -.infinity)
        #expect(spectrum.bands.allSatisfy { $0 == 0 })
        #expect(tracker.track(frames: [], count: Int.max).isEmpty)
    }

    @Test("echo-cancellation headroom is applied exactly once")
    func echoHeadroom() throws {
        let allocation = try #require(
            EchoCancellationCapacityPolicy.captureAllocation(
                requestedSliceFrames: 4_096,
                deviceSliceFrames: 4_096))
        #expect(allocation.bufferFrames == 16_384)
        #expect(
            EchoCancellationCapacityPolicy.captureAllocation(
                requestedSliceFrames: 16_384,
                deviceSliceFrames: 4_096) == nil)

        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let bridgeStart = try #require(
            source.range(of: "if let settings = echoCancellation"))
        let bridgeEnd = try #require(
            source.range(
                of: "let cancelsEcho = bridge != nil",
                range: bridgeStart.upperBound..<source.endIndex))
        let bridge = source[bridgeStart.lowerBound..<bridgeEnd.upperBound]
        #expect(bridge.contains("let echoSliceFrames = Int(exactly: bufferFrames)"))
        #expect(bridge.contains("maximumFrames: echoSliceFrames"))
        #expect(!bridge.contains("checkedProduct"))
    }
}
