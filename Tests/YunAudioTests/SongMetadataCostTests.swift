import Foundation
import Testing

@testable import YunAudioApp

/// Guards the supported asynchronous metadata boundary.
///
/// The old test benchmarked deprecated synchronous AVAsset access and thereby
/// required production to keep an I/O-capable call on MainActor. Latency is now
/// bounded structurally: one active async load, one pending latest request, and
/// stale results revoked before publication.
@Suite("song metadata loading")
struct SongMetadataCostTests {
    @Test("production metadata uses supported asynchronous asset properties")
    func supportedMetadataSurface() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let loader = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LocalSongMetadataWorker.swift",
            encoding: .utf8)
        let player = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LocalSongPlayer.swift",
            encoding: .utf8)

        #expect(loader.contains("await asset.load(.commonMetadata)"))
        #expect(loader.contains("await item.load(.stringValue)"))
        #expect(loader.contains("await item.load(.dataValue)"))
        #expect(!player.contains("asset.commonMetadata"))
        #expect(!player.contains(".first?.stringValue"))
        #expect(!player.contains(".first?.dataValue"))
    }
}
