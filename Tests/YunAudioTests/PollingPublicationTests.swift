import Foundation
import Testing
import YunAudioEngine

@testable import YunAudioApp

@Suite("Polling publications")
struct PollingPublicationTests {
    @Test("a stable feature-heavy minute publishes no identical values")
    func stableMinuteSuppressesNoOpPublications() {
        let polls = 20 * 60
        let routeCount = 2
        let dynamicsMeters = 2

        var peakHolds = [Float](repeating: 0, count: routeCount)
        var gainReduction = [Float](repeating: 0, count: dynamicsMeters)
        let analysis = SignalAnalyser.Reading.silent
        var attempted = 0
        var publications = 0

        for poll in 0..<polls {
            for index in peakHolds.indices {
                attempted += 1
                let incoming = RouterModel.nextPeakHold(
                    previous: peakHolds[index],
                    incoming: 0)
                if RouterModel.shouldPublish(
                    current: peakHolds[index],
                    incoming: incoming)
                {
                    peakHolds[index] = incoming
                    publications += 1
                }
            }

            attempted += 1
            if RouterModel.shouldPublish(current: analysis, incoming: .silent) {
                publications += 1
            }
            attempted += 1
            if RouterModel.shouldPublish(current: Double(0), incoming: Double(0)) {
                publications += 1
            }

            if poll.isMultiple(of: 4) {
                // Stable key and transpose suggestion.
                attempted += 2
                publications += RouterModel.shouldPublish(current: 3, incoming: 3) ? 1 : 0
                publications += RouterModel.shouldPublish(current: -2, incoming: -2) ? 1 : 0
            }
            if poll.isMultiple(of: 5) {
                attempted += 1
                publications += RouterModel.shouldPublish(current: 1, incoming: 1) ? 1 : 0
            }

            for index in gainReduction.indices {
                attempted += 1
                let incoming = RouterModel.nextGainReduction(
                    previous: gainReduction[index],
                    incoming: 0)
                if RouterModel.shouldPublish(
                    current: gainReduction[index],
                    incoming: incoming)
                {
                    gainReduction[index] = incoming
                    publications += 1
                }
            }

            attempted += 1
            publications +=
                RouterModel.shouldPublish(current: Double(0), incoming: Double(0))
                ? 1 : 0
        }

        print(
            "stable feature-heavy minute: \(attempted) attempted observable writes, "
                + "\(publications) publications")
        #expect(attempted == 9_240)
        #expect(publications == 0)
    }

    @Test("the publication gate handles every polled value shape")
    func gatePreservesChangedValues() {
        #expect(!RouterModel.shouldPublish(current: Float(0.25), incoming: Float(0.25)))
        #expect(
            !RouterModel.shouldPublish(
                current: [Float(0.1), 0.2],
                incoming: [Float(0.1), 0.2]))
        #expect(
            !RouterModel.shouldPublish(
                current: SignalAnalyser.Reading.silent,
                incoming: SignalAnalyser.Reading.silent))
        #expect(
            !RouterModel.shouldPublish(
                current: Optional<Float>.some(0),
                incoming: Optional<Float>.some(0)))

        #expect(RouterModel.shouldPublish(current: Float(0.25), incoming: Float(0.5)))
        #expect(
            RouterModel.shouldPublish(
                current: [Float(0.1), 0.2],
                incoming: [Float(0.1), 0.3]))
        #expect(
            RouterModel.shouldPublish(
                current: Optional<Float>.none,
                incoming: Optional<Float>.some(0)))
    }

    @Test("meter ballistics retain their rise and decay")
    func meterBallisticsAreNumericallyUnchanged() {
        #expect(RouterModel.nextPeakHold(previous: 0, incoming: 0) == 0)
        #expect(RouterModel.nextPeakHold(previous: 0.2, incoming: 0.8) == 0.8)
        #expect(
            abs(RouterModel.nextPeakHold(previous: 0.8, incoming: 0.2) - 0.776)
                < 0.000_001)

        #expect(RouterModel.nextGainReduction(previous: 0, incoming: 0) == 0)
        #expect(RouterModel.nextGainReduction(previous: 2, incoming: 8) == 8)
        #expect(
            abs(RouterModel.nextGainReduction(previous: 8, incoming: 2) - 6.92)
                < 0.000_001)
    }

    @Test("every high-frequency observable write uses the publication gate")
    func pollingPathsUseTheGate() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/RouterModel.swift"),
            encoding: .utf8)

        for statement in [
            "publish(key, to: \\.songKey)",
            "to: \\.suggestedShift)",
            "to: \\.scoringReferenceMode)",
            "publish(engine.recordingDuration, to: \\.recordingSeconds)",
            "publish(held, at: index, to: \\.peakHolds)",
            "to: \\.gainReduction)",
            "publish(analyser.reading(), to: \\.analysis)",
            "publish(offset, to: \\.autoLevelOffset)",
        ] {
            #expect(source.contains(statement), "missing publication gate: \(statement)")
        }
    }
}
