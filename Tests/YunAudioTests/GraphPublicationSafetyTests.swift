import CoreAudio
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Graph publication safety")
struct GraphPublicationSafetyTests {
    private struct CallbackContext: @unchecked Sendable {
        let input: UnsafeMutablePointer<AudioBufferList>
        let output: UnsafeMutablePointer<AudioBufferList>
        let cell: OpaquePointer

        func run() -> (status: OSStatus, nanoseconds: UInt64) {
            var now = AudioTimeStamp()
            var time = AudioTimeStamp()
            time.mFlags = .sampleTimeValid
            let started = DispatchTime.now().uptimeNanoseconds
            let status = yunAudioIOProc(
                0, &now, UnsafePointer(input), &time, output, &time,
                UnsafeMutableRawPointer(cell))
            return (status, DispatchTime.now().uptimeNanoseconds - started)
        }
    }

    private struct TelemetryHandle: @unchecked Sendable {
        let raw: OpaquePointer
    }

    private final class TelemetryResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storedReads = 0
        private var storedTornFrames = 0

        var reads: Int { lock.withLock { storedReads } }
        var tornFrames: Int { lock.withLock { storedTornFrames } }

        func record(torn: Bool) {
            lock.withLock {
                storedReads += 1
                if torn { storedTornFrames += 1 }
            }
        }
    }

    private func route(gain: Float = 1) -> RTRoute {
        RTRoute(
            sourceBuffer: 0, sourceChannel: 0,
            destinationBuffer: 0, destinationChannel: 0,
            gain: gain)
    }

    private func history(
        _ graph: UnsafeMutablePointer<RTGraph>, slot: Int
    ) -> UnsafeMutablePointer<RTGraph.AlignmentHistory> {
        graph.pointee.alignmentHistories[slot]
    }

    @Test("diagnostic generations count publication, not candidate preparation")
    func incidentGenerationCommitsAfterPublication() throws {
        let previous = RTGraph.allocate(routes: [route()])
        let next = RTGraph.allocate(routes: [route()])
        let telemetry = try #require(yun_rt_incident_callback_create())
        defer {
            yun_rt_incident_callback_free(telemetry)
            RTGraph.deallocate(previous)
            RTGraph.deallocate(next)
        }
        previous.pointee.incidentTelemetry = telemetry

        RTGraph.installStateHandover(from: previous, to: next, routeSlots: [0])
        #expect(yun_rt_incident_graph_generations(telemetry) == 1)

        RTGraph.recordPublication(of: UnsafePointer(next))
        #expect(yun_rt_incident_graph_generations(telemetry) == 2)
    }

    @Test("rapid generations adopt moving state on the realtime boundary")
    func chainedHandoverPreservesTheLastAudibleSample() {
        let first = RTGraph.allocate(routes: [route(gain: 1)])
        let second = RTGraph.allocate(routes: [route(gain: 0.75)])
        let third = RTGraph.allocate(routes: [route(gain: 0.5)])
        defer {
            RTGraph.deallocate(first)
            RTGraph.deallocate(second)
            RTGraph.deallocate(third)
        }

        first.pointee.routeGainSlews[0] = RTGainSlew(0)
        first.pointee.routeGainSlews[0].retargetLinear(to: 1, frames: 10)
        first.pointee.routeGainSlews[0].advanceLinear(frames: 4)
        first.pointee.peaks[0] = 0.875
        first.pointee.rms[0] = 0.25
        history(first, slot: 0).pointee.position = 73
        history(first, slot: 0).pointee.line[72] = 0.625
        first.pointee.outputPeak = 0.9375
        first.pointee.outputClipped = 19
        first.pointee.outputClippingEpoch = 4
        second.pointee.outputClippingEpoch = 4
        third.pointee.outputClippingEpoch = 4

        RTGraph.installStateHandover(from: first, to: second, routeSlots: [0])
        RTGraph.installStateHandover(from: second, to: third, routeSlots: [0])
        RTGraph.adoptStateHandover(on: third)

        #expect(first.pointee.stateHandover == nil)
        #expect(second.pointee.stateHandover == nil)
        #expect(third.pointee.stateHandover == nil)
        #expect(abs(third.pointee.routeGainSlews[0].current - 0.4) < 0.000_001)
        #expect(third.pointee.routeGainSlews[0].target == 0.5)
        #expect(third.pointee.peaks[0] == 0.875)
        #expect(third.pointee.rms[0] == 0.25)
        #expect(history(third, slot: 0).pointee.position == 73)
        #expect(history(third, slot: 0).pointee.line[72] == 0.625)
        #expect(third.pointee.outputPeak == 0.9375)
        #expect(third.pointee.outputClipped == 19)
    }

    @Test("reset epochs survive a publication before mailbox application")
    func resetEpochsArePublicationSafe() {
        let previous = RTGraph.allocate(routes: [route()])
        let next = RTGraph.allocate(routes: [route()])
        defer {
            RTGraph.deallocate(previous)
            RTGraph.deallocate(next)
        }
        previous.pointee.calibrating = 1
        previous.pointee.calibrationEpoch = 7
        previous.pointee.calibrationEnergy[0] = 81
        previous.pointee.calibrationFrames[0] = 9
        previous.pointee.outputClippingEpoch = 11
        previous.pointee.outputClipped = 23

        next.pointee.calibrating = 1
        next.pointee.calibrationEpoch = 8
        next.pointee.outputClippingEpoch = 12
        RTGraph.installStateHandover(from: previous, to: next, routeSlots: [0])
        RTGraph.adoptStateHandover(on: next)

        #expect(next.pointee.calibrationEnergy[0] == 0)
        #expect(next.pointee.calibrationFrames[0] == 0)
        #expect(next.pointee.outputClipped == 0)
    }

    @Test("route identities compose through unpublished generations")
    func chainedHandoverComposesRouteMaps() {
        let first = RTGraph.allocate(
            routes: [route(gain: 0.1), route(gain: 0.2), route(gain: 0.3)])
        let second = RTGraph.allocate(
            routes: [route(gain: 0.3), route(gain: 0.1)])
        let third = RTGraph.allocate(
            routes: [route(gain: 0.1), route(gain: 0.3), route(gain: 0.9)])
        defer {
            RTGraph.deallocate(first)
            RTGraph.deallocate(second)
            RTGraph.deallocate(third)
        }

        for index in 0..<3 {
            first.pointee.peaks[index] = Float(index + 1) / 10
            first.pointee.rms[index] = Float(index + 1) / 20
            first.pointee.routeGainSlews[index] = RTGainSlew(Float(index + 1) / 10)
            history(first, slot: index).pointee.position = Int32(101 + index)
            history(first, slot: index).pointee.line[100 + index] =
                Float(index + 1) / 8
        }
        RTGraph.installStateHandover(
            from: first, to: second, routeSlots: [2, 0])
        RTGraph.installStateHandover(
            from: second, to: third, routeSlots: [1, 0, nil])
        RTGraph.adoptStateHandover(on: third)

        #expect(third.pointee.peaks[0] == 0.1)
        #expect(third.pointee.peaks[1] == 0.3)
        #expect(third.pointee.peaks[2] == 0)
        #expect(third.pointee.rms[0] == 0.05)
        #expect(third.pointee.rms[1] == 0.15)
        #expect(third.pointee.routeGainSlews[0].current == 0.1)
        #expect(third.pointee.routeGainSlews[1].current == 0.3)
        #expect(third.pointee.routeGainSlews[2].current == 0.9)
        #expect(history(third, slot: 0).pointee.position == 101)
        #expect(history(third, slot: 1).pointee.position == 103)
        #expect(history(third, slot: 0).pointee.line[100] == 0.125)
        #expect(history(third, slot: 1).pointee.line[102] == 0.375)
    }

    @Test("graph retirement never owns the route analysis cursor")
    func sharedAnalysisRingOutlivesEveryGraph() throws {
        let shared = RTGraph.SharedAnalysisRing.allocate()
        let first = RTGraph.allocate(
            routes: [route()], sharedAnalysisRing: shared)
        let second = RTGraph.allocate(
            routes: [route()], sharedAnalysisRing: shared)

        #expect(first.pointee.analysisRing == shared.storage)
        #expect(second.pointee.analysisRing == shared.storage)
        #expect(first.pointee.ownsAnalysisRing == 0)
        #expect(second.pointee.ownsAnalysisRing == 0)
        RTGraph.deallocate(first)
        RTGraph.deallocate(second)

        var source: Float = 0.625
        var destination: Float = 0
        #expect(yun_rt_ring_write(shared.storage, &source, 1) == 1)
        #expect(yun_rt_ring_read(shared.storage, &destination, 1) == 1)
        #expect(destination == source)
        shared.deallocate()
    }

    @Test("the realtime route topology is admitted through sixty-four")
    func routeTopologyHasOneHardBound() {
        #expect(RTGraph.maximumRoutes == 64)
        #expect(RTGraph.supportsRouteCount(0))
        #expect(RTGraph.supportsRouteCount(64))
        #expect(!RTGraph.supportsRouteCount(65))
        #expect(RoutingEngine.acceptsRealtimeRouteCount(64))
        #expect(!RoutingEngine.acceptsRealtimeRouteCount(65))
    }

    @Test("twenty thousand concurrent meter frames are coherent")
    func telemetrySeqlockNeverReturnsAMixedCycle() throws {
        let telemetry = TelemetryHandle(
            raw: try #require(yun_rt_telemetry_create(2)))
        defer { yun_rt_telemetry_free(telemetry.raw) }
        var unpublishedPeak: Float = -1
        #expect(
            !yun_rt_telemetry_load(
                telemetry.raw, nil, nil, nil, nil, 0,
                &unpublishedPeak, nil, nil))
        #expect(unpublishedPeak == -1)
        let iterations = 20_000
        let result = TelemetryResult()
        let group = DispatchGroup()
        let writer = DispatchQueue(label: "yunaudio.test.telemetry-writer")
        let reader = DispatchQueue(label: "yunaudio.test.telemetry-reader")

        group.enter()
        writer.async {
            var peaks = [Float](repeating: 0, count: 2)
            var rms = [Float](repeating: 0, count: 2)
            var energy = [Double](repeating: 0, count: 2)
            var frames = [UInt64](repeating: 0, count: 2)
            for turn in 1...iterations {
                let scalar = Float(turn)
                peaks[0] = scalar
                peaks[1] = scalar
                rms[0] = scalar
                rms[1] = scalar
                energy[0] = Double(turn)
                energy[1] = Double(turn)
                frames[0] = UInt64(turn)
                frames[1] = UInt64(turn)
                yun_rt_telemetry_publish(
                    telemetry.raw, peaks, rms, energy, frames, 2,
                    scalar, UInt64(turn), UInt64(turn))
            }
            group.leave()
        }
        group.enter()
        reader.async {
            var peaks = [Float](repeating: 0, count: 2)
            var rms = [Float](repeating: 0, count: 2)
            var energy = [Double](repeating: 0, count: 2)
            var frames = [UInt64](repeating: 0, count: 2)
            var outputPeak: Float = 0
            var clipped: UInt64 = 0
            var failures: UInt64 = 0
            for _ in 0..<iterations {
                let loaded = yun_rt_telemetry_load(
                    telemetry.raw, &peaks, &rms, &energy, &frames, 2,
                    &outputPeak, &clipped, &failures)
                if loaded {
                    let expected = UInt64(outputPeak)
                    result.record(
                        torn: peaks[0] != outputPeak || peaks[1] != outputPeak
                            || rms[0] != outputPeak || rms[1] != outputPeak
                            || UInt64(energy[0]) != expected
                            || UInt64(energy[1]) != expected
                            || frames[0] != expected || frames[1] != expected
                            || clipped != expected || failures != expected)
                }
            }
            group.leave()
        }
        group.wait()

        #expect(yun_rt_telemetry_route_count(telemetry.raw) == 2)
        #expect(result.reads > 0)
        #expect(result.tornFrames == 0)
    }

    #if DEBUG
        @Test(
            "the maximum eight-link handover allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("the maximum eight-link handover allocates nothing")
    #endif
    func handoverHasNoRealtimeAllocation() {
        let graphCount = RTGraph.maximumStateHandoverDepth + 1
        let shared = RTGraph.SharedAlignmentHistory.allocate()
        let graphs = (0..<graphCount).map { index in
            RTGraph.allocate(
                routes: [route(gain: Float(index + 1) / Float(graphCount))],
                sharedAlignmentHistories: [shared])
        }
        defer {
            for graph in graphs { RTGraph.deallocate(graph) }
            shared.deallocate()
        }
        for index in 1..<graphs.count {
            RTGraph.installStateHandover(
                from: graphs[index - 1], to: graphs[index], routeSlots: [0])
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        RTGraph.adoptStateHandover(on: graphs[graphs.count - 1])
        yun_rt_tripwire_mark_realtime(false)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before

        print("8-link graph handover: \(elapsed) ns, \(allocations) allocations")
        #expect(allocations == 0)
        #expect(elapsed < 333_334)
        #expect(
            graphs.allSatisfy {
                $0.pointee.alignmentHistories[0] == shared.storage
                    && $0.pointee.ownsAlignmentHistories == 0
            })
    }

    #if DEBUG
        @Test(
            "a saturated handover fits the shortest supported cycle",
            .disabled("deadline evidence requires an optimised build"))
    #else
        @Test("a saturated handover fits the shortest supported cycle")
    #endif
    func saturatedHandoverFitsOneCycle() {
        let routeCount = RTGraph.maximumRoutes
        let routeList = (0..<routeCount).map { _ in route(gain: 0.5) }
        let histories = (0..<routeCount).map { _ in
            RTGraph.SharedAlignmentHistory.allocate()
        }
        let graphs = (0...RTGraph.maximumStateHandoverDepth).map { _ in
            RTGraph.allocate(
                routes: routeList, bufferFrames: 64, sampleRate: 96_000,
                sharedAlignmentHistories: histories)
        }
        defer {
            for graph in graphs { RTGraph.deallocate(graph) }
            for history in histories { history.deallocate() }
        }
        for (routeIndex, history) in histories.enumerated() {
            history.storage.pointee.position = Int32(100 + routeIndex)
            for frame in 0..<RTGraph.maximumAlignmentFrames {
                history.storage.pointee.line[frame] = Float((frame + routeIndex) & 255) / 255
            }
        }
        for generation in 1..<graphs.count {
            graphs[generation].pointee.alignmentFrames = 128
            RTGraph.installStateHandover(
                from: graphs[generation - 1], to: graphs[generation],
                routeSlots: (0..<routeCount).map(Optional.some))
        }

        let frames = 64
        let input = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        input.initialize(repeating: 0.25, count: frames)
        defer {
            input.deinitialize(count: frames)
            input.deallocate()
        }
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        output.initialize(repeating: 0, count: frames)
        defer {
            output.deinitialize(count: frames)
            output.deallocate()
        }
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        inputList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(input))
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        outputList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(output))
        defer { free(outputList.unsafeMutablePointer) }
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graphs.last!))!
        defer { yun_rt_cell_free(cell) }
        let callback = CallbackContext(
            input: inputList.unsafeMutablePointer,
            output: outputList.unsafeMutablePointer,
            cell: cell)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let coldBefore = RoutingEngine.allocationViolations
        let prewarmStatus = RTGraph.prewarmRealtimeRuntime()
        let coldAllocations = RoutingEngine.allocationViolations - coldBefore
        let before = RoutingEngine.allocationViolations
        // Core Audio enters on a different thread from route construction. A
        // separate serial queue proves the warm-up is process-wide rather than
        // merely hiding one thread's first-touch cost.
        let measured = DispatchQueue(label: "yunaudio.test.maximum-rt-callback")
            .sync { callback.run() }
        let allocations = RoutingEngine.allocationViolations - before

        print(
            "callback prewarm: \(coldAllocations) cold allocations; "
                + "64-route, 8-link first production callback: "
                + "\(measured.nanoseconds) ns, \(allocations) allocations")
        #expect(prewarmStatus == noErr)
        #expect(measured.status == noErr)
        #expect(allocations == 0)
        // This includes both the maximum publication chain and the ordinary
        // maximum-topology mix inside the shortest advertised device period.
        #expect(measured.nanoseconds < 666_667)
        #expect(graphs.last!.pointee.stateHandover == nil)
        #expect(
            graphs.allSatisfy { graph in
                (0..<routeCount).allSatisfy { routeIndex in
                    graph.pointee.alignmentHistories[routeIndex]
                        == histories[routeIndex].storage
                }
            })
        #expect(output[0].isFinite && output[0] > 0)
    }
}
