import CoreAudio
import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Bounded incident driver health lane")
struct AudioIncidentDriverHealthLaneTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() { lock.withLock { storage += 1 } }
        var value: Int { lock.withLock { storage } }
    }

    @Test("a timed-out read owns the sole worker and no replacement starts")
    func timeoutDoesNotMultiplyServerReads() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lane = BoundedAudioIncidentDriverHealthLane(
            label: "yunaudio.test.incident-health.timeout"
        ) { _, required, _ in
            entered.signal()
            release.wait()
            return AudioIncidentDriverHealth(
                state: .available, wasRequired: required, readStatus: 0,
                unsafeReadOperations: 7, unsafeWriteOperations: 11)
        }

        let first = DispatchQueue.global(qos: .utility).sync {
            lane.read(deviceID: 1, wasRequired: true, timeout: 0.01)
        }
        #expect(entered.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(first.state == .readFailed)

        let refused = lane.read(deviceID: 1, wasRequired: true, timeout: 0.01)
        #expect(refused.state == .readFailed)
        #expect(lane.statistics.reads == 1)
        #expect(lane.statistics.refused == 1)
        #expect(lane.statistics.timedOut == 1)
        #expect(lane.statistics.maximumConcurrent == 1)
        release.signal()
    }

    @Test("the lane reopens only after the original property read returns")
    func lateReturnReopensAdmission() {
        let returned = DispatchSemaphore(value: 0)
        let lane = BoundedAudioIncidentDriverHealthLane(
            label: "yunaudio.test.incident-health.recovery"
        ) { _, required, _ in
            returned.signal()
            return AudioIncidentDriverHealth(
                state: .available, wasRequired: required, readStatus: 0,
                unsafeReadOperations: 3, unsafeWriteOperations: 5)
        }

        let first = lane.read(deviceID: 1, wasRequired: false, timeout: 1)
        #expect(returned.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(first.state == .available)
        let second = lane.read(deviceID: 1, wasRequired: false, timeout: 1)
        #expect(second.state == .available)
        #expect(lane.statistics.reads == 2)
        #expect(lane.statistics.maximumConcurrent == 1)
    }

    @Test("a request which expires in the queue starts no HAL read")
    func queueDelayConsumesTheCallerDeadline() {
        let worker = DispatchQueue(label: "yunaudio.test.incident-health.queued")
        let occupied = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        worker.async {
            occupied.signal()
            _ = release.wait(timeout: .now() + TestGate.deadlock)
        }
        #expect(occupied.wait(timeout: .now() + TestGate.deadlock) == .success)

        let calls = Counter()
        let lane = BoundedAudioIncidentDriverHealthLane(
            label: "yunaudio.test.incident-health.absolute-deadline",
            workerQueue: worker
        ) { _, required, _ in
            calls.increment()
            return AudioIncidentDriverHealth(
                state: .available, wasRequired: required, readStatus: 0,
                unsafeReadOperations: 0, unsafeWriteOperations: 0)
        }
        let result = lane.read(deviceID: 1, wasRequired: true, timeout: 0.01)
        #expect(result.state == .readFailed)
        #expect(calls.value == 0)
        let refused = lane.read(deviceID: 2, wasRequired: false, timeout: 0.01)
        #expect(refused.state == .readFailed)
        #expect(lane.statistics.refused == 1)

        worker.async { drained.signal() }
        release.signal()
        #expect(drained.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(calls.value == 0)
        #expect(lane.statistics.reads == 1)
        #expect(lane.statistics.timedOut == 1)
        #expect(lane.statistics.expiredBeforeEntry == 1)
        #expect(lane.statistics.maximumConcurrent == 1)
    }
}
