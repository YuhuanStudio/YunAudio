import Testing

@testable import YunAudioApp

@Suite("Exact now-playing control scripts")
struct NowPlayingControlScriptTests {
    @Test("native transport verifies the song before the command")
    func nativeTransportIsIdentityBound() throws {
        let script = NowPlaying.exactTransportScript(
            .next, application: "Music", expectedIdentity: "song-\"one\\two")
        let identity = try #require(script.range(of: "id of current track"))
        let command = try #require(script.range(of: "next track"))

        #expect(identity.lowerBound < command.lowerBound)
        #expect(script.contains("song-\\\"one\\\\two"))
        #expect(script.contains("return \"\""))
    }

    @Test("native seek uses a locale-independent value after the identity guard")
    func nativeSeekIsIdentityBound() throws {
        let script = NowPlaying.exactSeekScript(
            seconds: 12.375, application: "Spotify", expectedIdentity: "track-7")
        let identity = try #require(script.range(of: "id of current track"))
        let mutation = try #require(script.range(of: "set player position to 12.375"))

        #expect(identity.lowerBound < mutation.lowerBound)
        #expect(!script.contains("12,375"))
    }

    @Test("browser controls compare the exact URL inside JavaScript")
    func browserControlIsIdentityBound() throws {
        let identity = "https://example.test/watch?v=one\"two\\three\u{2028}four"
        let transport = try #require(
            BrowserNowPlaying.script(for: .playPause, expectedIdentity: identity))
        let seek = try #require(
            BrowserNowPlaying.seekScript(
                toSeconds: 9.5, expectedIdentity: identity))
        let literal = BrowserNowPlaying.javaScriptLiteral(identity)

        #expect(transport.contains("location.href!==\(literal)"))
        #expect(seek.contains("location.href!==\(literal)"))
        #expect(transport.contains("return (function()"))
        #expect(seek.contains("currentTime=9.500"))
        #expect(literal.contains("\\u2028"))
        #expect(!literal.contains("\u{2028}"))
    }

    @Test("unknown or identity-free targets fail before sending an Apple event")
    func invalidTargetsFailClosed() {
        let context = NowPlayingControlContext(
            target: NowPlayingControlTarget(
                application: "Not a registered player", bundleIdentifier: nil,
                trackIdentity: "track"),
            targetEpoch: 1, requestToken: 1)
        #expect(
            !NowPlaying.apply(
                NowPlayingControlApplication(
                    context: context, command: .edge(.playPause))))

        let empty = NowPlayingControlContext(
            target: NowPlayingControlTarget(
                application: "Music", bundleIdentifier: "com.apple.Music",
                trackIdentity: ""),
            targetEpoch: 2, requestToken: 2)
        #expect(
            !NowPlaying.apply(
                NowPlayingControlApplication(
                    context: empty, command: .seek(seconds: 1))))
    }
}
