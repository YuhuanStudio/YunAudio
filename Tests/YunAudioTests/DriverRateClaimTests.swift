import Foundation
import Testing

@testable import YunAudioApp

/// What the README says the virtual device carries, against what it publishes.
///
/// The headline table said "44.1–192 kHz" beside Platform and Dependencies,
/// where it reads as the range this application handles. The virtual device —
/// the part that makes the project what it is — publishes four rates and 192
/// kHz is not among them. A physical-to-physical route does reach 192, so the
/// claim was not false everywhere; it was false about the one path most people
/// take.
///
/// The driver is C in its own build and cannot export a constant here, so the
/// declaration is read from the source.
@Suite("The driver's rates are claimed as they are published")
struct DriverRateClaimTests {

    private static func driverRates() throws -> [Double] {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Driver/Sources/YunAudioDriver.c", encoding: .utf8)
        let start = try #require(source.range(of: "kSupportedSampleRates[] = {"))
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "}"))
        return rest[..<end.lowerBound]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    @Test("the driver publishes exactly the rates the README describes")
    func readmeMatchesTheDriver() throws {
        let rates = try Self.driverRates()
        #expect(rates == [44_100, 48_000, 88_200, 96_000])

        let readme = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests + "README.md",
            encoding: .utf8)
        // The bound the driver actually has, stated where somebody reads it.
        #expect(readme.contains("44.1–96 kHz through the virtual device"))
        // And the old claim, which said 192 without qualification, is gone.
        #expect(!readme.contains("| **Formats** | 44.1–192 kHz;"))
    }
}
