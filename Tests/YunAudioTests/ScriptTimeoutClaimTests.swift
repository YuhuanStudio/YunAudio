import Foundation
import Testing

@testable import YunAudioApp

/// What the MCP server promises a script, against what the service gives it.
///
/// The description told clients "A script is stopped after two seconds" while
/// `ScriptService.executionTimeLimit` was 0.25 — eight times shorter. The
/// audience for that sentence is a language model writing a script it has no
/// other way to time, so a wrong number there is not documentation drift; it is
/// a contract that cannot be met.
///
/// The two live in different targets and cannot share a constant — the MCP
/// server is its own executable and cannot import the application — so they are
/// held in step here instead.
@Suite("The script timeout is promised as it is enforced")
struct ScriptTimeoutClaimTests {

    @Test("the MCP description states the real limit")
    func descriptionMatchesTheService() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let tools = try String(
            contentsOfFile: root + "Sources/yunaudio-mcp/MCPTools.swift", encoding: .utf8)
        let milliseconds = Int((ScriptService.executionTimeLimit * 1000).rounded())
        #expect(
            tools.contains("stopped after \(milliseconds) milliseconds"),
            "the description does not state \(milliseconds) ms")
        // And nothing left claiming the old figure.
        #expect(!tools.contains("stopped after two seconds"))
    }

    /// The limit is a quarter of a second, which is short enough that stating
    /// it wrongly matters: the difference between the promise and the enforcement
    /// was the whole of a script's budget and then some.
    @Test("the enforced limit is what this test was written against")
    func limitIsWhatWeThink() {
        #expect(ScriptService.executionTimeLimit == 0.25)
    }
}
