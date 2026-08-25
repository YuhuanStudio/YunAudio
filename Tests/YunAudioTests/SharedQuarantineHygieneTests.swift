import Foundation
import Testing

@testable import YunAudioHAL

/// A test that wedges a constructor must not wedge the process.
///
/// `ProcessLifetimeAudioQuarantine.shared` is exactly what its name says: an
/// entry retained there refuses new audio ownership for the rest of the
/// process. `BoundedAudioUnitConstructionLane` defaults to it, correctly, since
/// the shipping lanes all want it.
///
/// A test that builds its own lane and then deliberately times a constructor
/// out inherits that default and leaves an entry behind. One did, on
/// 2026-08-26, and the consequence was three unrelated formant tests failing
/// four runs in five with "graph admission was refused" — a staging-path fault
/// that had never happened, in a file nobody had touched.
///
/// The mistake is one omitted argument and is invisible at the call site, so it
/// is checked here rather than remembered.
@Suite("Tests do not poison the shared quarantine")
struct SharedQuarantineHygieneTests {

    /// Every lane a test constructs names the quarantine it will use.
    @Test("a lane built in a test supplies its own quarantine")
    func lanesInTestsSupplyAQuarantine() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests + "Tests/YunAudioTests/"
        let names = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.hasSuffix(".swift") }
        var offenders: [String] = []
        for name in names {
            let source = try String(contentsOfFile: root + name, encoding: .utf8)
            // The construction call, not the `.shared` or `.echoCancellation`
            // properties: those are the shipping lanes and are meant to use it.
            var searched = source[...]
            while let call = searched.range(of: "BoundedAudioUnitConstructionLane(") {
                let tail = searched[call.upperBound...].prefix(200)
                if !tail.contains("quarantine:") {
                    offenders.append("\(name): \(tail.prefix(60))")
                }
                searched = searched[call.upperBound...]
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: " | "))")
    }

    /// And the reason it matters, asserted rather than described: one retained
    /// entry is enough to refuse everything after it.
    @Test("one retained entry refuses new audio ownership")
    func oneEntryRefusesEverything() {
        final class Owner {}
        let quarantine = ProcessLifetimeAudioQuarantine()
        #expect(quarantine.refusalForNewAudioOwnership() == nil)
        let token = quarantine.retain(
            Owner(), reason: "a constructor that never returned")
        #expect(quarantine.refusalForNewAudioOwnership() != nil)
        quarantine.release(token)
        #expect(quarantine.refusalForNewAudioOwnership() == nil)
    }
}
