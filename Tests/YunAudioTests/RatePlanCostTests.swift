import Foundation
import Testing

@testable import YunAudioEngine

/// What choosing the higher rate actually costs.
@Suite("The rate a route lands on")
struct RatePlanCostTests {

    /// What the higher rate actually costs, which is not what was written down.
    ///
    /// `sampleRatePlan`'s comment says 96 kHz "doubles every per-frame DSP
    /// cost". Measured on this chain it does not: the same two seconds of audio
    /// costs about five per cent more, because these units are dominated by
    /// per-buffer overhead rather than per-sample work.
    ///
    /// The real cost is in the other direction and is arithmetic. A buffer is
    /// counted in frames, so at twice the rate the same buffer is half the wall
    /// time: 512 frames is 10.67 ms at 48 kHz and 5.33 ms at 96. The work per
    /// cycle barely moves and the deadline it has to fit inside halves, which
    /// is where crackle comes from — and it is a better reason for not taking
    /// the higher rate gratuitously than the one that was there.
    @Test("the higher rate halves the deadline while barely changing the work")
    func higherRateCostsProcessor() {
        let effects: [EffectKind] = [.equaliser, .gate, .compressor, .limiter]
        // Warmed first, and each rate measured twice with the better taken.
        //
        // The first version of this read 96 kHz as *cheaper* than 48, which is
        // impossible: the first call in the process pays for component
        // discovery and instantiation, and 48 kHz went first. A measurement
        // that says doubling the samples costs less is measuring the setup.
        for rate in [48_000.0, 96_000.0] {
            _ = SignalFidelity.cost(
                of: effects, on: SignalFidelity.fixture(seconds: 0.2, sampleRate: rate),
                sampleRate: rate)
        }
        var costs: [Double: Double] = [:]
        for rate in [48_000.0, 96_000.0] {
            // Two seconds of *audio* either way, so the comparison is per
            // second of sound rather than per sample.
            let source = SignalFidelity.fixture(seconds: 2, sampleRate: rate)
            var best = Double.infinity
            for _ in 0..<3 {
                let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                _ = SignalFidelity.cost(of: effects, on: source, sampleRate: rate)
                let spent =
                    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began)
                    / 1_000_000
                best = min(best, spent)
            }
            costs[rate] = best
        }
        let low = costs[48_000] ?? 0
        let high = costs[96_000] ?? 0
        let frames = 512.0
        print(
            String(
                format: "\nvoice scene over 2 s of audio:"
                    + "\n  48 kHz  %.1f ms CPU   %.2f ms per %.0f-frame cycle"
                    + "\n  96 kHz  %.1f ms CPU   %.2f ms per %.0f-frame cycle"
                    + "\n  CPU ratio %.2f, deadline ratio %.2f\n",
                low, frames / 48_000 * 1_000, frames,
                high, frames / 96_000 * 1_000, frames,
                low > 0 ? high / low : 0, 0.5))
        #expect(low > 0)
        // Not a multiple. The comment claimed one and there is not one, which
        // is the finding: anything under about 1.6 says the per-sample story is
        // wrong for this chain.
        #expect(high < low * 1.6, "48 kHz \(low) ms, 96 kHz \(high) ms")
    }

    /// And the rule itself, which is what the cost argues about.
    @Test("a common rate does not mean the highest common rate")
    func sharedRateIsNotTheHighest() {
        // A 48/96 microphone into a 48/96 destination, with nothing asked for.
        let plan = RoutingEngine.sampleRatePlan(
            sourceRates: [48_000, 96_000],
            destinationRates: [48_000, 96_000],
            preferredRate: nil,
            sourceCurrentRate: 96_000)
        // 48 kHz carries everything a microphone capsule produces and costs
        // half as much to process. Choosing 96 because both ends can is paying
        // twice for nothing.
        #expect(plan?.targetRate == 48_000, "chose \(plan?.targetRate ?? 0)")
        #expect(plan?.hasMismatch == false)
    }

    /// Asking for something is still honoured, at either end of the range.
    @Test("a rate somebody asked for is the rate they get")
    func preferredWins() {
        let high = RoutingEngine.sampleRatePlan(
            sourceRates: [48_000, 96_000], destinationRates: [48_000, 96_000],
            preferredRate: 96_000, sourceCurrentRate: 48_000)
        #expect(high?.targetRate == 96_000)

        let low = RoutingEngine.sampleRatePlan(
            sourceRates: [44_100, 48_000], destinationRates: [44_100, 48_000],
            preferredRate: 44_100, sourceCurrentRate: 48_000)
        #expect(low?.targetRate == 44_100)
    }

    /// And where the preferred rate is not available at both ends, the shared
    /// rate nearest it wins rather than the largest.
    @Test("without the asked-for rate, the nearest shared one is taken")
    func nearestSharedRate() {
        let plan = RoutingEngine.sampleRatePlan(
            sourceRates: [44_100, 88_200, 176_400],
            destinationRates: [44_100, 88_200, 176_400],
            preferredRate: 48_000,
            sourceCurrentRate: 176_400)
        #expect(plan?.targetRate == 44_100, "chose \(plan?.targetRate ?? 0)")
    }
}
