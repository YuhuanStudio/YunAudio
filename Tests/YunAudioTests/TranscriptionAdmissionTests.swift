import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Transcription admission")
struct TranscriptionAdmissionTests {
    private func sources(_ count: Int) -> [TranscriptionAdmission.Source] {
        (0..<count).map {
            TranscriptionAdmission.Source(uid: "source-\($0)", name: "Source \($0)")
        }
    }

    @Test(
        "one two four eight and sixty-four sources stop at four models",
        arguments: [(1, 1), (2, 2), (4, 4), (8, 4), (64, 4)])
    func sourceBoundary(requested: Int, expected: Int) {
        let plan = TranscriptionAdmission.plan(sources(requested))

        #expect(plan.admitted.count == expected)
        #expect(plan.refused.count == requested - expected)
        #expect(plan.resources.sourceCount == expected)
        #expect(plan.resources.converterLanes == expected)
        #expect(plan.resources.resultTasks == expected)
        #expect(plan.resources.modelInstances == expected)
        #expect(plan.resources.concurrentStarts == min(expected, 2))
        #expect(plan.resources.ringBytes == expected * 262_144)
        #expect(plan.resources.backlogBytes == expected * 768_000)
        #expect(plan.resources.analyzerInputs == expected * 32)
    }

    @Test("the global maximum is one MiB of rings and 2.93 MiB of backlog")
    func exactResourceCeiling() {
        #expect(TranscriptionAdmission.maximumSources == 4)
        #expect(TranscriptionAdmission.ringBytesPerSource == 262_144)
        #expect(TranscriptionAdmission.backlogBytesPerSource == 768_000)
        #expect(TranscriptionAdmission.maximumRingBytes == 1_048_576)
        #expect(TranscriptionAdmission.maximumBacklogBytes == 3_072_000)
        #expect(TranscriptionAdmission.maximumAnalyzerInputs == 128)

        // One 48-kHz mono Float copy per source: 0.18310546875 MiB/s.
        let copyMiBPerSecond =
            Double(4 * 48_000 * MemoryLayout<Float>.stride) / Double(1_024 * 1_024)
        #expect(abs(copyMiBPerSecond - 0.732_421_875) < 0.000_000_001)
    }

    @Test("stable identity and every refusal survive admission")
    func refusalIdentity() {
        let requested = sources(8)
        let plan = TranscriptionAdmission.plan(requested)

        #expect(plan.admitted == Array(requested.prefix(4)))
        #expect(plan.refused.map(\.source) == Array(requested.suffix(4)))
        #expect(
            plan.refused.allSatisfy {
                $0.reason == .sourceLimit(maximum: TranscriptionAdmission.maximumSources)
            })
    }

    @Test("duplicate UIDs consume no second model and name the rejected request")
    func duplicateUID() throws {
        let first = TranscriptionAdmission.Source(uid: "same", name: "Microphone")
        let duplicate = TranscriptionAdmission.Source(uid: "same", name: "Second label")
        let plan = TranscriptionAdmission.plan([first, duplicate])

        #expect(plan.admitted == [first])
        let refusal = try #require(plan.refused.first)
        #expect(refusal.source == duplicate)
        #expect(refusal.reason == .duplicateUID)
        #expect(plan.resources.modelInstances == 1)
    }

    @Test("empty and overlong source identity never reaches a model")
    func identityBounds() {
        let requested = [
            TranscriptionAdmission.Source(uid: "", name: "Empty UID"),
            TranscriptionAdmission.Source(
                uid: String(repeating: "u", count: 1_025), name: "Large UID"),
            TranscriptionAdmission.Source(uid: "empty-name", name: ""),
            TranscriptionAdmission.Source(
                uid: "large-name", name: String(repeating: "n", count: 4_097)),
        ]
        let plan = TranscriptionAdmission.plan(requested)

        #expect(plan.admitted.isEmpty)
        #expect(
            plan.refused.map(\.reason)
                == [
                    .emptyUID, .uidTooLarge(maximumBytes: 1_024), .emptyName,
                    .nameTooLarge(maximumBytes: 4_096),
                ])
        #expect(plan.resources.modelInstances == 0)
        #expect(plan.resources.ringBytes == 0)
    }
}
