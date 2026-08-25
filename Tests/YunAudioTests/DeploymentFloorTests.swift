import Foundation
import Testing

/// The lowest macOS this application runs on, asserted rather than assumed.
///
/// Three files have to agree — `Package.swift` compiles against it, the
/// `Info.plist` is what Launch Services refuses on, and the README is what
/// somebody reads before downloading. They are edited by different hands at
/// different times, and a disagreement is silent in every direction: a plist
/// floor above the compiled one turns away Macs that would have run it, and one
/// below it launches on a Mac where a symbol is missing.
@Suite("The deployment floor")
struct DeploymentFloorTests {

    /// The floor is process taps — `AudioHardwareCreateProcessTap`, macOS 14.2 —
    /// which is the one facility here with no alternative. Everything else that
    /// wanted a newer system was either gated or replaced: Swift's `Atomic` is
    /// macOS 15 and became the C11 atomics the realtime layer already used, and
    /// `textRenderer` is macOS 15 and guards a benchmark control.
    static let floor = "14.2"

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // YunAudioTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository
    }

    @Test("the package, the plist and the README name the same version")
    func everyDeclarationAgrees() throws {
        let root = Self.repositoryRoot()

        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains(".macOS(\"\(Self.floor)\")"))

        let plist = try String(
            contentsOf: root.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        #expect(
            plist.contains(
                "<key>LSMinimumSystemVersion</key>\n\t<string>\(Self.floor)</string>"))

        // The badge and the requirements list, because somebody deciding
        // whether to download this reads those and not the plist.
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("macOS \(Self.floor) or later"))
        #expect(
            readme.contains("macOS-\(Self.floor.replacingOccurrences(of: ".", with: "."))%2B"))
    }

    /// Nothing may reintroduce the symbol that was holding the floor up.
    ///
    /// `import Synchronization` compiles perfectly well and raises the whole
    /// application's floor to macOS 15 from wherever it is written, without any
    /// diagnostic saying so — the build only fails once somebody lowers the
    /// platform, which is the opposite order from the one that catches it.
    @Test("nothing imports Synchronization")
    func synchronisationStaysOut() throws {
        let sources = Self.repositoryRoot().appendingPathComponent("Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(atPath: sources.path))
        var offenders: [String] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let contents = try String(
                contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            if contents.contains("import Synchronization") { offenders.append(relative) }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: ", "))")
    }
}
