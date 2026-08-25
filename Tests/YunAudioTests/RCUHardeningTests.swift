import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("RCU retirement")
struct RCUHardeningTests {
    /// The test owns the cell until the worker has left its simulated callback.
    private final class CellHandle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }
    }

    @Test("a stalled reader keeps its retired generation alive past the timeout")
    func stalledReaderKeepsRetiredGeneration() throws {
        let first = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        first.initialize(to: 0xA11C_E001)
        let second = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        second.initialize(to: 0xA11C_E002)
        defer {
            first.deinitialize(count: 1)
            first.deallocate()
            second.deinitialize(count: 1)
            second.deallocate()
        }

        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(first)))
        let handle = CellHandle(cell)
        let loaded = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            _ = yun_rt_cell_load(handle.pointer)
            loaded.signal()
            _ = resume.wait(timeout: .now() + TestGate.deadlock)
            yun_rt_cell_retire(handle.pointer)
            _ = yun_rt_cell_load(handle.pointer)
            yun_rt_cell_retire(handle.pointer)
            finished.signal()
        }
        reader.start()
        #expect(loaded.wait(timeout: .now() + 2) == .success)

        #expect(
            yun_rt_cell_publish(cell, UnsafeMutableRawPointer(second))
                == UnsafeMutableRawPointer(first))
        let fence = yun_rt_cell_retirement_fence(cell)
        var reclaimed = false
        let retirements = RTGenerationRetirementQueue(maximumPending: 2)
        retirements.attach(to: cell)
        #expect(
            retirements.enqueue(safeAfterCycle: fence) {
                reclaimed = true
            })

        // This is the old implementation's dangerous case: the callback is
        // alive but cannot advance the counter. Timing out must retain, not
        // reinterpret the absence of progress as proof that no reader exists.
        #expect(!yun_rt_cell_wait_until(cell, fence, 5))
        #expect(retirements.collectReady() == 0)
        #expect(retirements.pendingCount == 1)
        #expect(!reclaimed)
        #expect(first.pointee == 0xA11C_E001)

        // A public non-reentrancy guarantee was not found in the HAL contract.
        // If it ever overlaps this stalled reader, those calls must touch no
        // graph and, critically, must not advance its retirement fence.
        for _ in 0..<100 {
            #expect(yun_rt_cell_load(cell) == nil)
        }
        #expect(yun_rt_cell_overlaps(cell) == 100)
        #expect(!yun_rt_cell_has_reached(cell, fence))

        resume.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(yun_rt_cell_wait_until(cell, fence, 100))
        // The automatic poll may win this race; either it or this explicit
        // collection has to reclaim exactly the one queued generation.
        let collectedHere = retirements.collectReady()
        #expect(collectedHere == 0 || collectedHere == 1)
        let reclaimDeadline = Date().addingTimeInterval(2)
        while retirements.pendingCount != 0, Date() < reclaimDeadline {
            usleep(1_000)
        }
        #expect(retirements.pendingCount == 0)
        #expect(reclaimed)

        retirements.detachAndReclaimAll()
        yun_rt_cell_free(cell)
    }

    @Test("the retirement queue refuses unbounded generations while audio is stalled")
    func retirementQueueIsBounded() throws {
        let cell = try #require(yun_rt_cell_create(nil))
        let retirements = RTGenerationRetirementQueue(maximumPending: 2)
        retirements.attach(to: cell)
        let fence = yun_rt_cell_retirement_fence(cell)

        #expect(retirements.enqueue(safeAfterCycle: fence) {})
        #expect(retirements.enqueue(safeAfterCycle: fence) {})
        #expect(!retirements.enqueue(safeAfterCycle: fence) {})
        #expect(retirements.pendingCount == 2)

        retirements.detachAndReclaimAll()
        yun_rt_cell_free(cell)
    }
}

@Suite("Atomic clock publication")
struct AtomicClockPublicationTests {
    private final class ClockHandle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }
    }

    @Test("concurrent readers never observe a mixed timestamp pair")
    func timestampsStayFromOnePublication() throws {
        let clock = try #require(yun_rt_clock_create())
        let handle = ClockHandle(clock)
        let finished = DispatchSemaphore(value: 0)
        let publications = 250_000
        let writer = Thread {
            for generation in 1...publications {
                yun_rt_clock_publish(
                    handle.pointer,
                    Double(generation),
                    UInt64(generation) &* 3 &+ 7)
            }
            finished.signal()
        }
        writer.start()

        var successfulReads = 0
        var mixedReads = 0
        while finished.wait(timeout: .now()) != .success {
            var sampleTime = 0.0
            var hostTime: UInt64 = 0
            if yun_rt_clock_load(clock, &sampleTime, &hostTime) {
                // Zero is the deliberately unpublished initial state. It has no
                // host clock yet and production rejects it for the same reason.
                if sampleTime == 0, hostTime == 0 { continue }
                successfulReads += 1
                let generation = UInt64(sampleTime)
                if sampleTime != Double(generation)
                    || hostTime != generation &* 3 &+ 7
                {
                    mixedReads += 1
                }
            }
        }
        #expect(successfulReads > 1_000)
        #expect(mixedReads == 0)

        var finalSampleTime = 0.0
        var finalHostTime: UInt64 = 0
        #expect(yun_rt_clock_load(clock, &finalSampleTime, &finalHostTime))
        #expect(finalSampleTime == Double(publications))
        #expect(finalHostTime == UInt64(publications) * 3 + 7)
        yun_rt_clock_free(clock)
    }
}
