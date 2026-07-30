import Foundation
import Testing

@Suite("Signing capability truth")
struct SigningCapabilityTests {
    @Test("the ad-hoc builder does not invent a macOS Shazam entitlement")
    func noInventedShazamEntitlement() throws {
        let source = try contents("App/build-app.sh")
        #expect(source.contains("com.apple.security.device.audio-input"))
        #expect(source.contains("com.apple.security.automation.apple-events"))
        #expect(!source.contains("<key>com.apple.developer.shazamkit</key>"))
    }

    @Test("an ad-hoc build says automatic catalogue identification is unavailable")
    func adHocWarning() throws {
        let source = try contents("App/build-app.sh")
        #expect(source.contains("Shazam catalogue: unavailable in this ad-hoc build."))
        #expect(source.contains("ShazamKit App Service enabled"))
        #expect(source.contains("runtime verification"))
    }

    @Test("Developer ID packaging never claims a signature proves catalogue access")
    func developerIDIsNotProof() throws {
        let source = try contents("package.sh")
        #expect(source.contains("Shazam catalogue: unverified."))
        #expect(source.contains("A Developer ID signature is not proof"))
        #expect(source.contains("explicit App ID with ShazamKit enabled"))
        #expect(source.contains("must still be verified at runtime"))
        #expect(source.contains("codesign --verify --deep --strict"))
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests + relativePath,
            encoding: .utf8)
    }
}
