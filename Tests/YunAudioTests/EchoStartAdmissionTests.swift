import Foundation
import Testing

@testable import YunAudioEngine

/// The effect chain's graph admission is given back before the canceller is
/// asked to start.
///
/// It was taken for the chain and released by a `defer` at the end of
/// `startAttempt`, so it was still outstanding when `bridge.start()` ran — and
/// starting the canceller goes through the sole disposer, which refuses while
/// any graph admission is. The disposer said so, once it was asked to say
/// anything at all:
///
///     ····  disposer answered blockedByRetainedTransaction(retainedUnits: 1)
///     ····  capture.startRaw returned false
///     2001 ms  start the echo canceller
///
/// Two seconds of waiting, then a failed route and a teardown that timed out.
/// Echo cancellation with *one* effect could not start; either on its own was
/// fine, which is what made it look like Core Audio's fault for a day.
@Suite("The canceller starts with no admission outstanding")
struct EchoStartAdmissionTests {

    private static func startAttempt() throws -> Substring {
        let source = try String(
            contentsOfFile: GraphLockDisciplineTests.enginePath, encoding: .utf8)
        let start = try #require(
            source.range(of: "var audioUnitPublicationAdmission: AudioUnitGraphAdmissionBox?"))
        let end = try #require(
            source.range(
                of: "let startStatus = timed(\"AudioDeviceStart\")",
                range: start.upperBound..<source.endIndex))
        return source[start.lowerBound..<end.lowerBound]
    }

    /// The release comes before the start, which is the whole fix.
    @Test("the admission is released before the canceller is started")
    func admissionIsReleasedFirst() throws {
        let body = try Self.startAttempt()
        let release = try #require(
            body.range(
                of:
                    "audioUnitPublicationAdmission?.release()\n        audioUnitPublicationAdmission = nil"
            ))
        let start = try #require(body.range(of: "bridge.start()"))
        #expect(release.lowerBound < start.lowerBound)
    }

    /// And the `defer` stays, because it is what releases on every path that
    /// throws before reaching the start.
    @Test("the failure path still releases it")
    func deferStillReleases() throws {
        let body = try Self.startAttempt()
        #expect(body.contains("defer { audioUnitPublicationAdmission?.release() }"))
    }
}
