import Testing

@testable import YunAudioEngine

@Suite("Sample-rate conversion policy")
struct SampleRateConversionPolicyTests {
    @Test("a mismatched Bluetooth output does not double the source DSP rate")
    func mismatchHonoursPreferredSourceRate() throws {
        let plan = try #require(
            RoutingEngine.sampleRatePlan(
                sourceRates: [48_000, 96_000],
                destinationRates: [44_100],
                preferredRate: 48_000,
                sourceCurrentRate: 96_000))

        #expect(plan.targetRate == 48_000)
        #expect(plan.hasMismatch)
        #expect(plan.targetRate / 96_000 == 0.5)
    }

    @Test("a mismatch preserves the source clock when the preference is unavailable")
    func mismatchPreservesCurrentSourceRate() throws {
        let plan = try #require(
            RoutingEngine.sampleRatePlan(
                sourceRates: [48_000, 96_000],
                destinationRates: [44_100],
                preferredRate: 88_200,
                sourceCurrentRate: 48_000))

        #expect(plan == .init(targetRate: 48_000, hasMismatch: true))
    }

    @Test("a shared preferred rate avoids nominal conversion")
    func sharedPreferenceWins() throws {
        let plan = try #require(
            RoutingEngine.sampleRatePlan(
                sourceRates: [44_100, 48_000, 96_000],
                destinationRates: [44_100, 48_000],
                preferredRate: 48_000,
                sourceCurrentRate: 96_000))

        #expect(plan == .init(targetRate: 48_000, hasMismatch: false))
    }

    @Test("the highest common rate wins without a usable preference")
    func highestCommonFallback() throws {
        let plan = try #require(
            RoutingEngine.sampleRatePlan(
                sourceRates: [44_100, 48_000, 96_000],
                destinationRates: [44_100, 48_000],
                preferredRate: nil,
                sourceCurrentRate: 96_000))

        #expect(plan == .init(targetRate: 48_000, hasMismatch: false))
    }

    @Test("invalid advertisements cannot become graph rates")
    func rejectsInvalidSourceRates() {
        #expect(
            RoutingEngine.sampleRatePlan(
                sourceRates: [0, -.infinity, .nan],
                destinationRates: [44_100],
                preferredRate: 48_000,
                sourceCurrentRate: 48_000) == nil)
    }
}
