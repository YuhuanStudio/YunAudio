import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

private final class DiagnosticEngineBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var exited = false

    func block() {
        condition.lock()
        defer {
            exited = true
            condition.broadcast()
            condition.unlock()
        }
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
    }

    var hasEntered: Bool {
        condition.withLock { entered }
    }

    var hasExited: Bool {
        condition.withLock { exited }
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

}

private final class CalibrationPermitState: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    private var reads = 0
    private var result: RoutingEngine.CalibrationMutationResult?

    func revoke() { lock.withLock { current = false } }

    func read() -> Bool {
        lock.withLock {
            reads += 1
            return current
        }
    }

    func finish(_ value: RoutingEngine.CalibrationMutationResult) {
        lock.withLock { result = value }
    }

    var snapshot: (reads: Int, result: RoutingEngine.CalibrationMutationResult?) {
        lock.withLock { (reads, result) }
    }
}

@Suite("Diagnostic engine boundaries")
struct DiagnosticEngineBoundaryTests {
    @Test("owned self-test capture remains valid after raw graph storage is freed")
    func ownedCaptureOutlivesRawStorage() {
        let frames = 8_192
        let delay = 872
        let raw = RTSelftest.allocate(
            outBuffer: 0, outChannel: 0, inBuffer: 0, inChannel: 0,
            captureFrames: frames)
        let start = UInt64(delay + 4_096)
        raw.pointee.captureStartFrame.pointee = start
        for index in 0..<frames {
            raw.pointee.capture[index] =
                selftestSample(start &+ UInt64(index) &- UInt64(delay))
        }
        yun_rt_counter_store(raw.pointee.captureCount, UInt64(frames))

        let capture = RTSelftest.snapshot(raw)
        RTSelftest.deallocate(raw)
        let result = capture.evaluate(maximumDelayFrames: Int.max)

        #expect(capture.capturedFrames == frames)
        #expect(result.delayFrames == delay)
        #expect(result.comparedFrames == frames)
        #expect(result.exactMatches == frames)
        #expect(result.maxAbsoluteError == 0)
        #expect(SelftestCapture.maximumDelayFrames == 16_384)
    }

    @Test("published capture count is clamped to allocated storage")
    func corruptPublishedCountCannotEscapeCapacity() {
        let raw = RTSelftest.allocate(
            outBuffer: 0, outChannel: 0, inBuffer: 0, inChannel: 0,
            captureFrames: 128)
        yun_rt_counter_store(raw.pointee.captureCount, UInt64.max)
        let capture = RTSelftest.snapshot(raw)
        RTSelftest.deallocate(raw)

        #expect(capture.capturedFrames == 128)

        let engineRaw = RTSelftest.allocate(
            outBuffer: 0, outChannel: 0, inBuffer: 0, inChannel: 0,
            captureFrames: 128)
        yun_rt_counter_store(engineRaw.pointee.captureCount, UInt64.max)
        let engine = RoutingEngine()
        engine.installSelftestForTesting(engineRaw)
        #expect(
            engine.readSelftestProgress()
                == .available(generation: 1, graphGeneration: 1, fraction: 1))
        engine.installSelftestForTesting(nil)
    }

    @Test("one-megabyte capture is bounded and a held engine lock never waits")
    @MainActor
    func captureCostAndContentionAreBounded() async {
        let engine = RoutingEngine()
        let raw = RTSelftest.allocate(
            outBuffer: 0, outChannel: 0, inBuffer: 0, inChannel: 0,
            captureFrames: 262_144)
        let delay = 17
        let startFrame = UInt64(delay + 4_096)
        raw.pointee.captureStartFrame.pointee = startFrame
        for index in 0..<262_144 {
            raw.pointee.capture[index] =
                selftestSample(startFrame &+ UInt64(index) &- UInt64(delay))
        }
        yun_rt_counter_store(raw.pointee.captureCount, 262_144)
        engine.installSelftestForTesting(raw, generation: 47)

        let admissionStart = DispatchTime.now().uptimeNanoseconds
        guard case let .available(snapshot) = engine.captureSelftest() else {
            Issue.record("the installed capture was not available")
            return
        }
        let admissionSeconds =
            Double(DispatchTime.now().uptimeNanoseconds - admissionStart) / 1_000_000_000
        #expect(snapshot.generation == 47)
        #expect(snapshot.graphGeneration == 47)
        #expect(snapshot.lease.capturedFrames == 262_144)
        #expect(admissionSeconds < 0.002)

        var admissionDurations: [UInt64] = []
        admissionDurations.reserveCapacity(10_000)
        for _ in 0..<10_000 {
            let started = DispatchTime.now().uptimeNanoseconds
            guard case .available = engine.captureSelftest() else {
                Issue.record("an uncontended metadata admission was refused")
                return
            }
            admissionDurations.append(
                DispatchTime.now().uptimeNanoseconds - started)
        }
        admissionDurations.sort()
        let p99 = admissionDurations[9_899]
        let maximum = admissionDurations.last ?? .max
        #expect(p99 < 2_000_000)
        #expect(maximum < 8_000_000)

        // The engine may drop its graph owner before the diagnostic worker gets
        // scheduled. The lease is the only remaining owner and the fixed prefix
        // must still be exactly readable.
        #expect(engine.stop(timeout: 0.01) == .complete)
        let copied = snapshot.lease.capture()
        #expect(copied.capturedFrames == 262_144)
        let result = copied.evaluate(maximumDelayFrames: 64)
        #expect(result.delayFrames == delay)
        #expect(result.exactMatches == 262_144)
        #expect(result.maxAbsoluteError == 0)

        let barrier = DiagnosticEngineBarrier()
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting { barrier.block() }
        }
        while !barrier.hasEntered { await Task.yield() }
        defer { barrier.release() }
        let heldStarted = DispatchTime.now().uptimeNanoseconds

        var busyDurations: [UInt64] = []
        busyDurations.reserveCapacity(10_000)
        for _ in 0..<10_000 {
            let started = DispatchTime.now().uptimeNanoseconds
            guard case .busy = engine.captureSelftest(),
                engine.readSelftestProgress() == .busy
            else {
                Issue.record("a contended diagnostic read did not fail busy")
                return
            }
            busyDurations.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        busyDurations.sort()
        #expect(busyDurations[9_899] < 2_000_000)
        #expect((busyDurations.last ?? .max) < 8_000_000)
        let heldElapsed = DispatchTime.now().uptimeNanoseconds - heldStarted
        if heldElapsed < 250_000_000 {
            try? await Task.sleep(
                for: .nanoseconds(Int64(250_000_000 - heldElapsed)))
        }
        barrier.release()
        while !barrier.hasExited { await Task.yield() }
        #expect(DispatchTime.now().uptimeNanoseconds - heldStarted >= 250_000_000)
    }

    @Test("UI snapshot stays generation-coherent while the engine lock is held")
    @MainActor
    func uiSnapshotIsCoherentAndNonblocking() async {
        let engine = RoutingEngine()
        var sourceRoutes = [
            Route(
                source: ChannelRef(deviceUID: "source-generation-7", channel: 2),
                destination: ChannelRef(
                    deviceUID: "destination-generation-7", channel: 5),
                gain: 0.375, isMuted: true, isDuckable: true)
        ]
        let expected = RoutingEngine.EngineUISnapshot(
            generation: 83,
            routeGeneration: 7,
            graphGeneration: 11,
            routes: sourceRoutes,
            processingLatency: ProcessingLatency(
                sourceFrames: 287, outputFrames: 48),
            voiceIsolationLatencyFrames: 241,
            alignmentFrames: 287,
            failedPlugins: [
                AudioUnitLoadFailure(
                    name: "generation-11-plugin", reason: .formatRejected,
                    status: -10_868)
            ],
            droppedMonitor: RoutingEngine.DroppedMonitor(
                uid: "monitor-generation-11", reason: "not-started-generation-11"),
            droppedExtras: [
                RoutingEngine.DroppedMonitor(
                    uid: "extra-generation-11", reason: "not-joined-generation-11")
            ],
            isolationError: "isolation-generation-11",
            activeEffectStages: [.voiceIsolation, .limiter],
            effectUpdateRefusal: .unsupportedLatency(
                requested: 16_385, maximum: 16_384),
            holdsClockLock: true,
            echoCancellationStatus: nil,
            echoCancellationError: "echo-generation-11",
            echoCancellationDetail: "echo-detail-generation-11",
            outputDeviceUIDs: ["destination-generation-7"],
            correctionOutcome: .installed)
        #expect(engine.installEngineUISnapshotForTesting(expected))

        // Arrays are value-owned by the immutable publication. Mutating the
        // fixture after installation must not alter the retained generation.
        sourceRoutes[0].gain = 1
        #expect(expected.routes[0].gain == 0.375)
        #expect(expected.processingLatency.sourceFrames == 287)
        #expect(expected.processingLatency.outputFrames == 48)
        #expect(expected.totalProcessingLatencyFrames == 335)
        #expect(expected.alignmentFrames == 287)
        #expect(expected.voiceIsolationLatencyFrames == 241)

        let stale = RoutingEngine.EngineUISnapshot(
            generation: 82,
            routeGeneration: 6,
            graphGeneration: 10,
            routes: [],
            processingLatency: ProcessingLatency(
                sourceFrames: 1, outputFrames: 2),
            voiceIsolationLatencyFrames: 3,
            alignmentFrames: 4,
            failedPlugins: [],
            droppedMonitor: nil,
            droppedExtras: [],
            isolationError: nil,
            activeEffectStages: [],
            effectUpdateRefusal: nil,
            holdsClockLock: false,
            echoCancellationStatus: nil,
            echoCancellationError: nil,
            echoCancellationDetail: nil,
            outputDeviceUIDs: [],
            correctionOutcome: .nothingToInstall)
        #expect(!engine.installEngineUISnapshotForTesting(stale))

        let barrier = DiagnosticEngineBarrier()
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting { barrier.block() }
        }
        while !barrier.hasEntered { await Task.yield() }
        defer { barrier.release() }
        let heldStarted = DispatchTime.now().uptimeNanoseconds

        var durations: [UInt64] = []
        durations.reserveCapacity(10_000)
        for _ in 0..<10_000 {
            let started = DispatchTime.now().uptimeNanoseconds
            let observed = engine.engineUISnapshot
            let routes = engine.currentRoutes
            let processingLatency = engine.processingLatency
            let isolationLatency = engine.voiceIsolationLatencyFrames
            let alignment = engine.alignmentFrames
            let failures = engine.failedPlugins
            let droppedMonitor = engine.droppedMonitor
            let droppedExtras = engine.droppedExtras
            let isolationError = engine.lastIsolationError
            let stages = engine.activeEffectStages
            let refusal = engine.lastEffectUpdateRefusal
            durations.append(DispatchTime.now().uptimeNanoseconds - started)
            #expect(observed == expected)
            #expect(observed.routeGeneration == 7)
            #expect(observed.graphGeneration == 11)
            #expect(observed.failedPlugins[0].name == "generation-11-plugin")
            #expect(observed.droppedExtras[0].uid == "extra-generation-11")
            #expect(observed.totalProcessingLatencyFrames == 335)
            #expect(routes == expected.routes)
            #expect(processingLatency == expected.processingLatency)
            #expect(isolationLatency == 241)
            #expect(alignment == 287)
            #expect(failures == expected.failedPlugins)
            #expect(droppedMonitor == expected.droppedMonitor)
            #expect(droppedExtras == expected.droppedExtras)
            #expect(isolationError == "isolation-generation-11")
            #expect(stages == [.voiceIsolation, .limiter])
            #expect(refusal == expected.effectUpdateRefusal)
        }
        durations.sort()
        #expect(durations[9_899] < 2_000_000)
        #expect((durations.last ?? .max) < 8_000_000)

        let heldElapsed = DispatchTime.now().uptimeNanoseconds - heldStarted
        if heldElapsed < 250_000_000 {
            try? await Task.sleep(
                for: .nanoseconds(Int64(250_000_000 - heldElapsed)))
        }
        barrier.release()
        while !barrier.hasExited { await Task.yield() }
        #expect(DispatchTime.now().uptimeNanoseconds - heldStarted >= 250_000_000)

        let fresh = engine.engineUISnapshot
        #expect(fresh.generation == 84)
        #expect(fresh.routeGeneration == 0)
        #expect(fresh.graphGeneration == 0)
        #expect(fresh.routes.isEmpty)
    }

    @Test("calibration rechecks the newest intent only after taking the engine lock")
    func lateBeginLosesToCancel() async {
        let engine = RoutingEngine()
        let barrier = DiagnosticEngineBarrier()
        let permit = CalibrationPermitState()
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting { barrier.block() }
        }
        while !barrier.hasEntered { await Task.yield() }
        defer { barrier.release() }

        DispatchQueue.global(qos: .userInitiated).async {
            permit.finish(engine.setCalibrationActive(true, ifCurrent: permit.read))
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(permit.snapshot.reads == 0)

        permit.revoke()
        barrier.release()
        while permit.snapshot.result == nil { await Task.yield() }

        #expect(permit.snapshot.reads == 1)
        #expect(permit.snapshot.result == .revoked)
    }
}
