import CoreAudio
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

@Suite("Audio Unit product admission")
struct PluginAdmissionTests {
    private func plugin(
        _ index: Int, name: String? = nil, loadsInProcess: Bool = true,
        requiresAsyncInstantiation: Bool = false
    ) -> AudioUnitPlugin {
        AudioUnitPlugin(
            type: 1, subType: OSType(index + 1), manufacturer: 2,
            name: name ?? "plugin-\(index)", manufacturerName: "maker",
            loadsInProcess: loadsInProcess,
            requiresAsyncInstantiation: requiresAsyncInstantiation)
    }

    @Test("restoration retains sixteen unique in-process components in order")
    func restoredPlugins() {
        let requested = (0..<17).map { plugin($0) }
        let admitted = RouterModel.admittedPlugins(requested)
        #expect(admitted.count == RoutingEngine.maximumHostedPlugins)
        #expect(admitted.map(\.id) == requested.prefix(16).map(\.id))
    }

    @Test("remote, async-only, duplicate and oversized metadata never reach the model")
    func unsafePlugins() {
        let first = plugin(0)
        let duplicate = AudioUnitPlugin(
            type: first.type, subType: first.subType, manufacturer: first.manufacturer,
            name: "renamed", manufacturerName: "different", loadsInProcess: true)
        let remote = plugin(1, loadsInProcess: false)
        let oversized = plugin(2, name: String(repeating: "p", count: 1_025))
        let asyncOnly = plugin(3, requiresAsyncInstantiation: true)

        #expect(
            RouterModel.admittedPlugins(
                [first, duplicate, remote, oversized, asyncOnly]) == [first])
    }
}
