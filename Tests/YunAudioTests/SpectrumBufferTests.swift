import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Spectrum overlap buffer", .serialized)
struct SpectrumBufferTests {
    private func signal(count: Int, sampleRate: Double = 48_000) -> [Float] {
        (0..<count).map { index in
            let time = Double(index) / sampleRate
            return Float(
                0.31 * sin(2 * .pi * 173 * time)
                    + 0.19 * sin(2 * .pi * 997 * time)
                    + 0.07 * sin(2 * .pi * 4_321 * time))
        }
    }

    @Test("arbitrary block boundaries are numerically identical")
    func arbitraryBlockBoundaries() throws {
        let samples = signal(count: 48_137)
        let whole = try #require(SpectrumAnalyser(sampleRate: 48_000))
        samples.withUnsafeBufferPointer {
            whole.add($0.baseAddress!, count: $0.count)
        }

        let chunked = try #require(SpectrumAnalyser(sampleRate: 48_000))
        let sizes = [1, 17, 2_047, 3, 4_096, 513, 8_191]
        var offset = 0
        var block = 0
        samples.withUnsafeBufferPointer { buffer in
            while offset < buffer.count {
                let count = min(sizes[block % sizes.count], buffer.count - offset)
                chunked.add(buffer.baseAddress! + offset, count: count)
                offset += count
                block += 1
            }
        }

        #expect(chunked.bands == whole.bands)
        #expect(chunked.chroma(sampleRate: 48_000) == whole.chroma(sampleRate: 48_000))
    }

    #if DEBUG
        @Test(
            "a minute of steady spectrum analysis stays allocation free and bounded",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("a minute of steady spectrum analysis stays allocation free and bounded")
    #endif
    func steadyStatePerformance() throws {
        let analyser = try #require(SpectrumAnalyser(sampleRate: 48_000))
        let samples = signal(count: 60 * 48_000)

        samples.withUnsafeBufferPointer {
            analyser.add($0.baseAddress!, count: SpectrumAnalyser.windowSize * 2)
        }
        analyser.reset()

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        samples.withUnsafeBufferPointer { buffer in
            yun_rt_tripwire_mark_realtime(true)
            analyser.add(buffer.baseAddress!, count: buffer.count)
            yun_rt_tripwire_mark_realtime(false)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before
        let checksum = analyser.bands.enumerated().reduce(0.0) {
            $0 + Double($1.offset + 1) * Double($1.element)
        }

        print(
            "one-minute spectrum: \(elapsed) ns, \(allocations) allocations, "
                + "checksum \(checksum)")
        #expect(allocations == 0)
        #expect(elapsed < 250_000_000)
        #expect(checksum.isFinite && checksum > 0)
    }
}
