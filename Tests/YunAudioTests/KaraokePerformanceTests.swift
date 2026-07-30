import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// A score is rebuilt four times a second while the singing panel is open.
///
/// Short fixtures hide both bad shapes in that work: rescoring the whole song
/// grows with the duration, and an allocation inside the per-sample loop grows
/// with every pitched frame. Thirty minutes is an ordinary long session and
/// makes either mistake large enough to measure without a profiler.
@Suite("Karaoke score performance", .serialized)
struct KaraokePerformanceTests {
    #if DEBUG
        @Test(
            "a half-hour score stays bounded",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("a half-hour score stays bounded")
    #endif
    func halfHourScore() throws {
        let step = 2048.0 / 48_000
        let sung = stride(from: 0.0, to: 30 * 60, by: step).map {
            PitchSample(time: $0, midi: 60)
        }
        let reference = stride(from: 0.0, to: 30 * 60, by: 0.05).map {
            PitchSample(time: $0, midi: 60)
        }
        let key = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 1)
        let lyrics = stride(from: 0.0, to: 30 * 60, by: 4).map {
            Lyrics.Line(time: $0, text: "line")
        }

        // Warm lazy runtime and allocator paths before counting the operation.
        _ = KaraokeScore.keyScore(
            sung: Array(sung.prefix(100)), key: key,
            lyrics: Array(lyrics.prefix(2)), through: 8)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        let score = KaraokeScore.keyScoreChronological(
            sung: sung, sungStep: step, key: key, lyrics: lyrics,
            through: 30 * 60)
        yun_rt_tripwire_mark_realtime(false)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before

        let beforeExact = RoutingEngine.allocationViolations
        let exactStarted = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        let exact = KaraokeScore.scoreChronological(
            sung: sung, sungStep: step,
            reference: reference, referenceStep: 0.05,
            lyrics: lyrics, through: 30 * 60)
        yun_rt_tripwire_mark_realtime(false)
        let exactElapsed = DispatchTime.now().uptimeNanoseconds - exactStarted
        let exactAllocations = RoutingEngine.allocationViolations - beforeExact

        print(
            "half-hour key score: \(elapsed) ns, \(allocations) allocations, "
                + "\(sung.count) pitch samples")
        print(
            "half-hour exact score: \(exactElapsed) ns, \(exactAllocations) allocations, "
                + "\(reference.count) reference moments")
        #expect(score.percentage > 99)
        #expect(exact.percentage > 99)
        #expect(allocations <= 16, "one score allocated \(allocations) times")
        #expect(
            exactAllocations <= 16,
            "one exact score allocated \(exactAllocations) times")
        #expect(elapsed < 10_000_000, "one visible score took \(elapsed) ns")
        #expect(
            exactElapsed < 10_000_000,
            "one visible exact score took \(exactElapsed) ns")
    }
}
