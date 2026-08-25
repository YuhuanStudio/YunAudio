import CoreAudio
import Darwin
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// Compares the exact same realtime workload in debug and optimised builds.
///
/// Ten seconds is expressed as a fixed number of audio cycles rather than a
/// wall-clock loop. A faster build must not get credited with more work, and a
/// slower one must not be measured against fewer callbacks. The graph resembles
/// the common KTV arrangement: microphone to the main and monitor buses, plus a
/// stereo application source to the main bus.
@Suite("RTGraph build performance", .serialized)
struct RTGraphBuildPerformanceTests {
    private static let sampleRate = 48_000
    private static let frames = 128
    private static let audioSeconds = 10
    private static let expectedCycles = sampleRate * audioSeconds / frames

    /// One interleaved buffer per CoreAudio stream, retained for the whole run.
    private final class Bus {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        init(channelCounts: [Int], frames: Int) {
            list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
            for (bufferIndex, channels) in channelCounts.enumerated() {
                let sampleCount = frames * channels
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
                pointer.initialize(repeating: 0, count: sampleCount)
                for sampleIndex in 0..<sampleCount {
                    pointer[sampleIndex] =
                        Float((sampleIndex + bufferIndex * 17) % 61) / 61 - 0.5
                }
                storage.append(pointer)
                list[bufferIndex] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(pointer))
            }
        }

        var checksum: Double {
            storage.enumerated().reduce(0) { partial, entry in
                let (bufferIndex, pointer) = entry
                let sampleCount =
                    Int(list[bufferIndex].mDataByteSize) / MemoryLayout<Float>.size
                return partial
                    + (0..<sampleCount).reduce(0) {
                        $0 + Double(pointer[$1]) * Double($1 + 1)
                    }
            }
        }

        deinit {
            for pointer in storage { pointer.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    @Test("ten seconds reports allocations, cycles, and processor cost")
    func tenSecondBuildComparison() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 1, destinationChannel: 0,
                    appliesInputTrim: true),
                RTRoute(
                    sourceBuffer: 1, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    isDuckable: true),
                RTRoute(
                    sourceBuffer: 1, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1,
                    isDuckable: true),
            ],
            bufferFrames: Self.frames,
            sampleRate: Double(Self.sampleRate))
        defer { RTGraph.deallocate(graph) }
        let incident = yun_rt_incident_callback_create()!
        defer { yun_rt_incident_callback_free(incident) }
        graph.pointee.incidentTelemetry = incident
        graph.pointee.incidentDeadlineNanoseconds =
            UInt64(Self.frames) * 1_000_000_000 / UInt64(Self.sampleRate)
        graph.pointee.mainOutputBuffer = 0
        graph.pointee.masterExemptBuffer = 1

        let input = Bus(channelCounts: [1, 2], frames: Self.frames)
        let output = Bus(channelCounts: [2, 2], frames: Self.frames)
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }

        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid

        // Warm lazy runtime and Accelerate paths before either counter starts.
        for cycle in 0..<32 {
            time.mSampleTime = Float64(cycle * Self.frames)
            _ = yunAudioIOProc(
                0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
                output.list.unsafeMutablePointer, &time,
                UnsafeMutableRawPointer(cell))
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let allocationBaseline = RoutingEngine.allocationViolations
        let cycleBaseline = graph.pointee.cycleCounter.pointee
        let processorBaseline = Self.processorNanoseconds()
        let wallBaseline = DispatchTime.now().uptimeNanoseconds
        var combinedStatus = noErr
        for cycle in 0..<Self.expectedCycles {
            time.mSampleTime = Float64((cycle + 32) * Self.frames)
            combinedStatus |= yunAudioIOProc(
                0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
                output.list.unsafeMutablePointer, &time,
                UnsafeMutableRawPointer(cell))
        }
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - wallBaseline
        let processorNanoseconds = Self.processorNanoseconds() - processorBaseline
        let allocations = RoutingEngine.allocationViolations - allocationBaseline
        let cycles = graph.pointee.cycleCounter.pointee - cycleBaseline
        let realtimeCPUPercent =
            Double(processorNanoseconds)
            / Double(Self.audioSeconds * 1_000_000_000) * 100
        let cyclesPerProcessorSecond =
            Double(cycles) * 1_000_000_000 / Double(max(processorNanoseconds, 1))
        let checksum = output.checksum
        var callbackTail = YunRTIncidentCallbackSnapshot()
        yun_rt_incident_callback_snapshot(incident, false, &callbackTail)

        #if DEBUG
            let build = "debug"
        #else
            let build = "release"
        #endif
        print(
            "\(build) RTGraph 10s: \(allocations) allocations / \(cycles) cycles, "
                + "\(processorNanoseconds) processor ns (\(realtimeCPUPercent)% of one core), "
                + "\(wallNanoseconds) wall ns, \(cyclesPerProcessorSecond) cycles/CPU-s, "
                + "checksum \(checksum)")

        #expect(combinedStatus == noErr)
        #expect(cycles == Self.expectedCycles)
        #expect(callbackTail.samples == UInt64(Self.expectedCycles + 32))
        // A relationship that survives sampling, rather than an equality that
        // does not. The tail cannot record more violations than there were
        // allocations; whether it records every one depends on when its window
        // closed, and in a debug build — where the allocations come from
        // Swift's own checking machinery rather than from this graph — a loaded
        // machine routinely closes it between the two counts.
        //
        // In release both are zero and the exact claim is made below.
        #expect(callbackTail.allocationViolations <= allocations)
        #expect(!callbackTail.isCoherent)
        #expect(checksum.isFinite && abs(checksum) > 1)
        #if !DEBUG
            #expect(allocations == 0)
            #expect(callbackTail.allocationViolations == 0)
            #expect(realtimeCPUPercent < 5)
        #endif
    }

    /// Process CPU time excludes scheduling delays and is directly comparable
    /// with the percentage reported by the live soak command.
    private static func processorNanoseconds() -> UInt64 {
        var time = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0 else { return 0 }
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
}
