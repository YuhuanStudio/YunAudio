import Foundation
import Testing
import YunAudioEngine

@testable import YunAudioApp

@Suite("Polling publications")
struct PollingPublicationTests {
    @Test("callback continuity counts audible gaps without inventing them")
    func callbackContinuity() {
        var continuity = RouterModel.IOContinuity()
        for count in [100, 109, 118, 118, 118, 127, 127, 136] as [UInt64?] {
            continuity.observe(count)
        }

        #expect(continuity.cycleCount == 136)
        #expect(continuity.stalledPolls == 3)
        #expect(continuity.stallEvents == 2)
        #expect(!continuity.isStalled)

        continuity.observe(nil)
        #expect(continuity.stalledPolls == 3)
        #expect(continuity.stallEvents == 2)

        continuity.reset()
        #expect(continuity == RouterModel.IOContinuity())
    }

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

    @Test("stable ducking queues one graph command per state")
    func duckingPermissionPublishesOnlyTransitions() {
        var gate = DuckingAllowedGate()
        var commands = 0

        for _ in 0..<(20 * 60 * 60) {
            if gate.shouldSend(false) { commands += 1 }
        }
        #expect(commands == 1)

        for _ in 0..<(20 * 5) {
            if gate.shouldSend(true) { commands += 1 }
        }
        #expect(commands == 2)

        for _ in 0..<(20 * 5) {
            if gate.shouldSend(false) { commands += 1 }
        }
        #expect(commands == 3)

        gate.reset()
        let afterReset = gate.shouldSend(false)
        let duplicateAfterReset = gate.shouldSend(false)
        #expect(afterReset)
        #expect(!duplicateAfterReset)
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

    @Test("continuous peaks publish one discrete output verdict")
    func outputVerdictPublishesOnlyAtBoundaries() {
        let polls = 20 * 60
        let goodPeaks: [Float] = [0.08, 0.12, 0.16, 0.20]
        var peak: Float = 0
        var verdict = RouterModel.OutputVerdict.silent
        var peakPublications = 0
        var verdictPublications = 0

        for poll in 0..<polls {
            let incoming = goodPeaks[poll % goodPeaks.count]
            if RouterModel.shouldPublish(current: peak, incoming: incoming) {
                peak = incoming
                peakPublications += 1
            }
            let incomingVerdict = RouterModel.classifyOutput(
                peak: incoming, clippedSamples: 0)
            if RouterModel.shouldPublish(
                current: verdict,
                incoming: incomingVerdict)
            {
                verdict = incomingVerdict
                verdictPublications += 1
            }
        }

        print(
            "moving output peak: \(peakPublications) peak publications, "
                + "\(verdictPublications) status verdict publication in one minute")
        #expect(peakPublications == polls)
        #expect(verdictPublications == 1)
        #expect(verdict == .good)
    }

    @Test("the output verdict preserves every level and latch boundary")
    func outputVerdictBoundaries() {
        func peak(at decibels: Float) -> Float {
            pow(10, decibels / 20)
        }

        #expect(RouterModel.classifyOutput(peak: 0, clippedSamples: 0) == .silent)
        #expect(
            RouterModel.classifyOutput(
                peak: peak(at: -40), clippedSamples: 0)
                == .veryQuiet)
        #expect(
            RouterModel.classifyOutput(
                peak: peak(at: -30), clippedSamples: 0)
                == .quiet)
        #expect(
            RouterModel.classifyOutput(
                peak: peak(at: -12), clippedSamples: 0)
                == .good)
        #expect(
            RouterModel.classifyOutput(
                peak: peak(at: -2), clippedSamples: 0)
                == .hot)
        #expect(RouterModel.classifyOutput(peak: 1, clippedSamples: 0) == .clipping)
        #expect(
            RouterModel.classifyOutput(
                peak: peak(at: -40), clippedSamples: 1)
                == .clipping)
        #expect(RouterModel.classifyOutput(peak: .nan, clippedSamples: 0) == .silent)
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

    @Test("meter releases become an exact stable zero after an impulse")
    func meterReleaseStopsPublishing() {
        var peak: Float = 1
        var reduction: Float = 8
        var peakSettlePolls = 0
        var reductionSettlePolls = 0

        while peak != 0, peakSettlePolls < 20 * 60 {
            peak = RouterModel.nextPeakHold(previous: peak, incoming: 0)
            peakSettlePolls += 1
        }
        while reduction != 0, reductionSettlePolls < 20 * 60 {
            reduction = RouterModel.nextGainReduction(
                previous: reduction,
                incoming: 0)
            reductionSettlePolls += 1
        }

        var publications = 0
        for _ in 0..<(20 * 60) {
            let nextPeak = RouterModel.nextPeakHold(previous: peak, incoming: 0)
            let nextReduction = RouterModel.nextGainReduction(
                previous: reduction,
                incoming: 0)
            publications += nextPeak == peak ? 0 : 1
            publications += nextReduction == reduction ? 0 : 1
            peak = nextPeak
            reduction = nextReduction
        }

        print(
            "meter impulse settled after \(peakSettlePolls) peak polls and "
                + "\(reductionSettlePolls) reduction polls; "
                + "\(publications) publications in the following minute")
        #expect(peakSettlePolls < 20 * 60)
        #expect(reductionSettlePolls < 20 * 60)
        #expect(peak == 0)
        #expect(reduction == 0)
        #expect(publications == 0)
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
            "publish(snapshot.duration, to: \\.recordingSeconds)",
            "publish(held, at: index, to: \\.peakHolds)",
            "to: \\.gainReduction)",
            "publish(snapshot.reading, to: \\.analysis)",
            "publish(offset, to: \\.autoLevelOffset)",
            "to: \\.outputVerdict)",
        ] {
            #expect(source.contains(statement), "missing publication gate: \(statement)")
        }
    }
}
