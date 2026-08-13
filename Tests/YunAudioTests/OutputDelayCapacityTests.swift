import Testing

@testable import YunAudioApp

@Suite("Output-delay capacity")
struct OutputDelayCapacityTests {
    @Test("frame conversion is finite, active-only and exact at its ceiling")
    func frameAdmission() {
        #expect(
            RouterModel.outputLatencyFrames(
                delays: ["output": 500], sampleRate: 96_000,
                activeUIDs: ["output"])
                == ["output": 48_000])
        #expect(
            RouterModel.outputLatencyFrames(
                delays: ["output": 250], sampleRate: 192_000,
                activeUIDs: ["output"])
                == ["output": 48_000])

        for value in [250.001, Double.nan, .infinity, -.infinity, -1, 0] {
            #expect(
                RouterModel.outputLatencyFrames(
                    delays: ["output": value], sampleRate: 192_000,
                    activeUIDs: ["output"]
                )
                .isEmpty)
        }
        #expect(
            RouterModel.outputLatencyFrames(
                delays: ["stale": 10], sampleRate: 48_000,
                activeUIDs: ["output"]
            )
            .isEmpty)
        #expect(
            RouterModel.outputLatencyFrames(
                delays: ["output": 10], sampleRate: .nan,
                activeUIDs: ["output"]
            )
            .isEmpty)
    }

    @Test("restored delays retain at most sixteen finite bounded entries")
    func restoredAdmission() {
        var saved = Dictionary(
            uniqueKeysWithValues: (0..<17).map { ("output-\($0)", Double($0 + 1)) })
        saved["nan"] = .nan
        saved["infinite"] = .infinity
        saved["negative"] = -1
        saved["too-long"] = 501
        saved[String(repeating: "u", count: 1_025)] = 10

        let admitted = RouterModel.sanitisedOutputDelays(saved)
        #expect(admitted.count == 16)
        #expect(admitted.values.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 500 })
        #expect(admitted.keys.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1_024 })
    }
}
