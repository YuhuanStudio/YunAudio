import Foundation
import Testing
import YunAudioEngine

@testable import YunAudioApp

@Suite("Routing canvas performance")
struct RoutingCanvasPerformanceTests {
    @Test("position index includes headers and every channel exactly once")
    func positionIndexMatchesRows() {
        let groups = [
            PortGroup(uid: "microphone", name: "Microphone", channels: [0, 2]),
            PortGroup(uid: "music", name: "Music", channels: [0, 1, 3]),
        ]
        let positions = RoutingCanvasLayout.positions(for: groups, pitch: 20)

        #expect(positions.count == 5)
        #expect(positions[ChannelRef(deviceUID: "microphone", channel: 0)] == 30)
        #expect(positions[ChannelRef(deviceUID: "microphone", channel: 2)] == 50)
        #expect(positions[ChannelRef(deviceUID: "music", channel: 0)] == 90)
        #expect(positions[ChannelRef(deviceUID: "music", channel: 1)] == 110)
        #expect(positions[ChannelRef(deviceUID: "music", channel: 3)] == 130)
        #expect(positions[ChannelRef(deviceUID: "missing", channel: 0)] == nil)
    }

    @Test("enumerated levels stay aligned and silence still wins")
    func indexedLevelsPreserveMuteSemantics() {
        let levels: [Float] = [0.125, 0.5]
        #expect(RoutingCanvasLayout.level(at: 0, levels: levels, isSilenced: false) == 0.125)
        #expect(RoutingCanvasLayout.level(at: 1, levels: levels, isSilenced: false) == 0.5)
        #expect(RoutingCanvasLayout.level(at: 1, levels: levels, isSilenced: true) == 0)
        #expect(RoutingCanvasLayout.level(at: 2, levels: levels, isSilenced: false) == 0)
    }

    @Test("live levels have a child observation boundary")
    func liveLevelsStayOutOfPatchbayParent() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/RoutingCanvas.swift"),
            encoding: .utf8)
        let leafStart = try #require(source.range(of: "private struct LiveCables: View"))
        let parent = source[..<leafStart.lowerBound]
        let leaf = source[leafStart.lowerBound...]

        #expect(parent.ranges(of: "model.routeLevels").count == 0)
        #expect(leaf.ranges(of: "model.routeLevels").count == 1)
        #expect(leaf.contains("for (index, route) in routes.enumerated()"))
        #expect(!leaf.contains("model.level(of:"))
        #expect(parent.ranges(of: "RoutingCanvasLayout.positions(").count == 2)
    }

    #if DEBUG
        @Test(
            "indexed cable lookup stays materially below repeated port scans",
            .disabled("timing evidence requires an optimised build"))
    #else
        @Test("indexed cable lookup stays materially below repeated port scans")
    #endif
    func indexedLookupBenchmark() {
        let groups = (0..<16).map { device in
            PortGroup(
                uid: "device-\(device)",
                name: "Device \(device)",
                channels: Array(0..<16))
        }
        let references =
            groups.flatMap { group in
                group.channels.map {
                    ChannelRef(deviceUID: group.uid, channel: $0)
                }
            } + [ChannelRef(deviceUID: "missing", channel: 99)]
        let positions = RoutingCanvasLayout.positions(for: groups, pitch: 26)
        let repetitions = 400

        var indexedChecksum: CGFloat = 0
        let indexedStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repetitions {
            for reference in references {
                indexedChecksum += positions[reference] ?? -1
            }
        }
        let indexedNanoseconds = DispatchTime.now().uptimeNanoseconds - indexedStarted

        var scannedChecksum: CGFloat = 0
        let scannedStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repetitions {
            for reference in references {
                scannedChecksum +=
                    Self.scannedPosition(
                        of: reference,
                        in: groups,
                        pitch: 26) ?? -1
            }
        }
        let scannedNanoseconds = DispatchTime.now().uptimeNanoseconds - scannedStarted

        print(
            "\(references.count * repetitions) cable endpoints: "
                + "index \(indexedNanoseconds) ns, scan \(scannedNanoseconds) ns, "
                + "speedup \(Double(scannedNanoseconds) / Double(indexedNanoseconds))x, "
                + "checksum \(indexedChecksum)")
        #expect(indexedChecksum == scannedChecksum)
        #expect(scannedNanoseconds > indexedNanoseconds * 5)
    }

    /// The implementation replaced by the position index, retained here only
    /// as an executable numerical and timing baseline.
    private static func scannedPosition(
        of reference: ChannelRef,
        in groups: [PortGroup],
        pitch: CGFloat
    ) -> CGFloat? {
        var row = 0
        for group in groups {
            row += 1
            for channel in group.channels {
                if group.uid == reference.deviceUID, channel == reference.channel {
                    return CGFloat(row) * pitch + pitch / 2
                }
                row += 1
            }
        }
        return nil
    }
}
