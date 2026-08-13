import AppKit
import Darwin
import Foundation
import YunDesign

/// The view state a UI measurement holds while it counts work.
///
/// `section69` is named after the flow-check section which exposed the layout
/// storm. It reproduces that section's visible boundary without opening an
/// audio file: the inspector owns the singing surface, the song is paused, key
/// controls are present and centre cancellation is absent.
enum UIResourceBenchmarkScenario: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case appOpen = "app-open"
    case panelClosed = "panel-closed"
    case windowMovement = "window-movement"
    case section69 = "section-69"
    case ktvStage = "ktv-stage"

    static func resolve(environment: [String: String]) -> Self? {
        Self(rawValue: environment["YUNAUDIO_UI_BENCHMARK_SCENARIO"] ?? "standard")
    }
}

/// The latency distribution required before a UI revision meets the responsiveness budget.
///
/// A maximum alone cannot distinguish one isolated stall from a main actor
/// which is late on every turn, while an average can hide either. The three
/// stated percentiles are therefore carried together and compared against the
/// same contract recorded in the hardening plan.
struct MainActorLatencyDistribution: Codable, Sendable, Equatable {
    static let maximumRetainedSamples = 131_072

    let samples: Int
    let p50Seconds: Double
    let p99Seconds: Double
    let maximumSeconds: Double

    init(
        samples: Int, p50Seconds: Double, p99Seconds: Double, maximumSeconds: Double
    ) {
        self.samples = samples
        self.p50Seconds = p50Seconds
        self.p99Seconds = p99Seconds
        self.maximumSeconds = maximumSeconds
    }

    init(nanoseconds: [UInt64]) {
        let ordered = nanoseconds.sorted()
        samples = ordered.count
        guard !ordered.isEmpty else {
            p50Seconds = .infinity
            p99Seconds = .infinity
            maximumSeconds = .infinity
            return
        }
        p50Seconds = Double(Self.nearestRank(0.50, in: ordered)) / 1e9
        p99Seconds = Double(Self.nearestRank(0.99, in: ordered)) / 1e9
        maximumSeconds = Double(ordered[ordered.count - 1]) / 1e9
    }

    var isValid: Bool {
        samples > 0
            && p50Seconds.isFinite
            && p99Seconds.isFinite
            && maximumSeconds.isFinite
            && p50Seconds >= 0
            && p50Seconds <= p99Seconds
            && p99Seconds <= maximumSeconds
    }

    private static func nearestRank(_ percentile: Double, in ordered: [UInt64]) -> UInt64 {
        let rank = max(1, Int(ceil(percentile * Double(ordered.count))))
        return ordered[min(ordered.count - 1, rank - 1)]
    }
}

/// Fail-closed evidence from every probe pass in one exact UI scenario.
///
/// Percentiles are the worst pass rather than a pooled average. Pooling could
/// let four healthy long passes hide one short, consistently late pass. Sample
/// counts are still totalled so the manifest proves how much of the requested
/// interval was observed.
struct MainActorScenarioEvidence: Codable, Sendable, Equatable {
    let passCount: Int
    let expectedSamples: Int
    let deliveredSamples: Int
    let producerMisses: Int
    let minimumSampleCoverage: Double
    let producer: MainActorLatencyDistribution
    let delivery: MainActorLatencyDistribution

    static func combine(_ evidence: [Self]) -> Self {
        guard !evidence.isEmpty else {
            let empty = MainActorLatencyDistribution(nanoseconds: [])
            return Self(
                passCount: 0, expectedSamples: 0, deliveredSamples: 0,
                producerMisses: 0, minimumSampleCoverage: 0,
                producer: empty, delivery: empty)
        }
        return Self(
            passCount: evidence.reduce(0) { $0 + $1.passCount },
            expectedSamples: evidence.reduce(0) { $0 + $1.expectedSamples },
            deliveredSamples: evidence.reduce(0) { $0 + $1.deliveredSamples },
            producerMisses: evidence.reduce(0) { $0 + $1.producerMisses },
            minimumSampleCoverage: evidence.map(\.minimumSampleCoverage).min() ?? 0,
            producer: worst(evidence.map(\.producer)),
            delivery: worst(evidence.map(\.delivery)))
    }

    private static func worst(
        _ distributions: [MainActorLatencyDistribution]
    ) -> MainActorLatencyDistribution {
        MainActorLatencyDistribution(
            samples: distributions.reduce(0) { $0 + $1.samples },
            p50Seconds: distributions.map(\.p50Seconds).max() ?? .infinity,
            p99Seconds: distributions.map(\.p99Seconds).max() ?? .infinity,
            maximumSeconds: distributions.map(\.maximumSeconds).max() ?? .infinity)
    }
}

/// Numeric refusal boundary for the layout-storm reproduction.
///
/// The observed failure consumed 14% of one core while the song was paused and
/// could starve the main thread for minutes. Five and ten per cent leave a wide
/// margin over the healthy fixture while still making that failure red. A
/// background clock also times delivery onto the main run loop: unlike a
/// `Task.sleep`, that measures the thread rather than cooperative-executor wake
/// coalescing. One hundred milliseconds is two missed 20 Hz UI frames. A
/// healthy ten-second sleep coalesced by 0.599 seconds while compilers shared
/// the host, so the wall budget is two seconds; the failure it detects was
/// measured in minutes, not scheduler-scale jitter.
struct UIResourceBenchmarkBudget {
    static let maximumStaticCoreFraction = 0.05
    static let maximumMovingCoreFraction = 0.10
    static let maximumMainRunLoopDeliveryLatency = 0.100
    static let maximumMainActorP50Latency = 0.0005
    static let maximumMainActorP99Latency = 0.002
    static let maximumMainActorLatency = 0.008
    static let maximumPassOverrun = 2.0
    static let promotionFrameSeconds = 1.0 / 120.0

    static func admitsMainActor(_ distribution: MainActorLatencyDistribution) -> Bool {
        distribution.isValid
            && distribution.p50Seconds <= maximumMainActorP50Latency
            && distribution.p99Seconds <= maximumMainActorP99Latency
            && distribution.maximumSeconds <= maximumMainActorLatency
    }

    static func admitsMainActor(_ evidence: MainActorScenarioEvidence) -> Bool {
        let aggregateCoverage =
            evidence.expectedSamples > 0
            ? Double(evidence.deliveredSamples) / Double(evidence.expectedSamples) : 0
        return evidence.passCount > 0
            && evidence.expectedSamples > 0
            && evidence.deliveredSamples >= 0
            && evidence.deliveredSamples <= evidence.expectedSamples
            && evidence.producer.isValid
            && evidence.producer.samples == evidence.deliveredSamples
            && evidence.delivery.samples == evidence.deliveredSamples
            && evidence.producerMisses
                == evidence.expectedSamples - evidence.deliveredSamples
            && evidence.minimumSampleCoverage.isFinite
            && evidence.minimumSampleCoverage >= UIBenchmarkContract.minimumSampleCoverage
            && evidence.minimumSampleCoverage <= aggregateCoverage + 1e-12
            && admitsMainActor(evidence.delivery)
    }

    static func admitsSection69(
        staticProcessorSeconds: Double,
        staticWallSeconds: Double,
        plannedStaticSeconds: Double,
        movingProcessorSeconds: Double,
        movingWallSeconds: Double,
        plannedMovingSeconds: Double,
        mainRunLoopDeliveryLatency: Double
    ) -> Bool {
        guard staticWallSeconds > 0, movingWallSeconds > 0 else { return false }
        return staticProcessorSeconds / staticWallSeconds <= maximumStaticCoreFraction
            && movingProcessorSeconds / movingWallSeconds <= maximumMovingCoreFraction
            && staticWallSeconds - plannedStaticSeconds <= maximumPassOverrun
            && movingWallSeconds - plannedMovingSeconds <= maximumPassOverrun
            && mainRunLoopDeliveryLatency <= maximumMainRunLoopDeliveryLatency
    }

    static func admitsWindowMovement(
        _ movement: MainActorLatencyDistribution,
        mainActor: MainActorScenarioEvidence
    ) -> Bool {
        movement.isValid
            && movement.p99Seconds <= promotionFrameSeconds
            // The 99th percentile measures sustained drag quality. The hard
            // maximum separately refuses a perceptible long hitch while
            // allowing one desktop-scheduler outlier in an eight-second run.
            && movement.maximumSeconds <= promotionFrameSeconds * 4
            && mainActor.passCount == 1
            && mainActor.minimumSampleCoverage >= UIBenchmarkContract.minimumSampleCoverage
            && mainActor.delivery.isValid
            && mainActor.delivery.p99Seconds <= promotionFrameSeconds
            && mainActor.delivery.maximumSeconds <= promotionFrameSeconds * 4
    }
}

/// Producer-side clock state, touched only by the probe's private serial queue.
private final class UIResourceProbeProducer: @unchecked Sendable {
    struct Result: Sendable {
        let expectedSamples: Int
        let missedSamples: Int
        let distribution: MainActorLatencyDistribution
    }

    private let beganAt: UInt64
    private let cadence: UInt64
    private var nextDeadline: UInt64
    private var samples = 0
    private var inferredMisses = 0
    private var retainedLateness: [UInt64] = []

    init(beganAt: UInt64, cadence: UInt64) {
        self.beganAt = beganAt
        self.cadence = cadence
        nextDeadline = beganAt + cadence
        retainedLateness.reserveCapacity(MainActorLatencyDistribution.maximumRetainedSamples)
    }

    func record(at now: UInt64) -> UInt64 {
        let lateness = now >= nextDeadline ? now - nextDeadline : 0
        let skipped = Int(lateness / cadence)
        inferredMisses += skipped
        nextDeadline += UInt64(skipped + 1) * cadence
        samples += 1
        if retainedLateness.count < MainActorLatencyDistribution.maximumRetainedSamples {
            retainedLateness.append(lateness)
        }
        return now
    }

    func finish(at now: UInt64) -> Result {
        let elapsed = now >= beganAt ? now - beganAt : 0
        let elapsedIntervals = Int(elapsed / cadence)
        let expected = max(samples + inferredMisses, elapsedIntervals, samples)
        let missed = max(0, expected - samples)
        let complete = retainedLateness.count == samples
        return Result(
            expectedSamples: expected,
            missedSamples: missed,
            distribution: MainActorLatencyDistribution(
                nanoseconds: complete ? retainedLateness : []))
    }
}

/// Allocation-bounded MainActor half of the run-loop latency probe.
@MainActor
final class MainActorDeliveryRecorder {
    struct Result: Sendable {
        let distribution: MainActorLatencyDistribution
        let maximumAtSeconds: Double
    }

    private let origin: UInt64
    private var maximumNanoseconds: UInt64 = 0
    private var maximumAtNanoseconds: UInt64 = 0
    private var samples = 0
    private var retainedLatencies: [UInt64] = []

    init(origin: UInt64) {
        self.origin = origin
        retainedLatencies.reserveCapacity(MainActorLatencyDistribution.maximumRetainedSamples)
    }

    func record(sentAt: UInt64, deliveredAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let delay = deliveredAt >= sentAt ? deliveredAt - sentAt : 0
        samples += 1
        if retainedLatencies.count < MainActorLatencyDistribution.maximumRetainedSamples {
            retainedLatencies.append(delay)
        }
        if delay > maximumNanoseconds {
            maximumNanoseconds = delay
            maximumAtNanoseconds = deliveredAt >= origin ? deliveredAt - origin : 0
        }
    }

    var result: Result {
        Result(
            distribution: MainActorLatencyDistribution(
                nanoseconds: samples == retainedLatencies.count ? retainedLatencies : []),
            maximumAtSeconds: Double(maximumAtNanoseconds) / 1e9)
    }
}

/// Times work sent from a background clock to the main run loop.
///
/// A Swift task's requested wake time is not a MainActor deadline. On an idle
/// process it was observed resuming 1.177–6.968 seconds late while 98.03% of a
/// simultaneous main-thread sample remained in `mach_msg2_trap`. Dispatching
/// timestamps from another queue measures the event we care about instead: how
/// long genuinely ready main-thread work waits before AppKit can run it.
@MainActor
private final class UIResourceMainRunLoopProbe {
    struct Result: Sendable {
        let maximumAtSeconds: Double
        let evidence: MainActorScenarioEvidence

        var maximumSeconds: Double { evidence.delivery.maximumSeconds }
        var samples: Int { evidence.deliveredSamples }
    }

    private let origin: UInt64
    private let queue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.ui-benchmark-liveness", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var producer: UIResourceProbeProducer?
    private let delivery: MainActorDeliveryRecorder

    init(origin: UInt64) {
        self.origin = origin
        delivery = MainActorDeliveryRecorder(origin: origin)
    }

    func start() {
        precondition(timer == nil)
        generation &+= 1
        let generation = generation
        let beganAt = DispatchTime.now().uptimeNanoseconds
        let cadence = UIBenchmarkContract.cadenceNanoseconds
        let producer = UIResourceProbeProducer(beganAt: beganAt, cadence: cadence)
        self.producer = producer
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: beganAt + cadence),
            repeating: .nanoseconds(Int(cadence)),
            leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            let sent = producer.record(at: DispatchTime.now().uptimeNanoseconds)
            MainRunLoopDelivery.perform { [weak self] in
                self?.record(sentAt: sent, generation: generation)
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// Cancels the source and drains a sentinel behind every delivery it sent.
    ///
    /// The source queue is serial, so the sentinel reaches the main run loop
    /// after its last timestamp. Awaiting it also yields the benchmark task,
    /// allowing delayed main-run-loop blocks to record before the result is read.
    func finish() async -> Result {
        timer?.cancel()
        timer = nil
        let producer = producer
        self.producer = nil
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let producerResult = producer?.finish(
                    at: DispatchTime.now().uptimeNanoseconds)
                MainRunLoopDelivery.perform { [self] in
                    generation &+= 1
                    continuation.resume(returning: result(producer: producerResult))
                }
            }
        }
    }

    private func record(sentAt: UInt64, generation: UInt64) {
        guard self.generation == generation else { return }
        delivery.record(sentAt: sentAt)
    }

    private func result(producer: UIResourceProbeProducer.Result?) -> Result {
        let delivery = delivery.result
        let empty = MainActorLatencyDistribution(nanoseconds: [])
        let expected = producer?.expectedSamples ?? 0
        let delivered = delivery.distribution.samples
        let coverage = expected == 0 ? 0 : Double(delivered) / Double(expected)
        return Result(
            maximumAtSeconds: delivery.maximumAtSeconds,
            evidence: MainActorScenarioEvidence(
                passCount: 1,
                expectedSamples: expected,
                deliveredSamples: delivered,
                producerMisses: producer?.missedSamples ?? expected,
                minimumSampleCoverage: coverage,
                producer: producer?.distribution ?? empty,
                delivery: delivery.distribution))
    }
}

/// A repeatable UI-only KTV workload.
///
/// The hardware flow check can say how much the whole process costs, but its
/// number includes the IO thread, CoreAudio and the poll that feeds the view.
/// This harness opens the real window and advances the same lyric clock at the
/// same twenty-hertz cadence without discovering a device, starting MIDI or
/// constructing a route. Static and moving passes share one process and one
/// view graph, so their difference belongs to the interface.
@MainActor
enum UIResourceBenchmark {
    private struct Usage {
        let processorSeconds: Double
        let footprintBytes: UInt64
    }

    private struct PassTiming {
        let wallSeconds: Double
        let maximumTaskSchedulingLateness: Double
        let mainRunLoopDelivery: UIResourceMainRunLoopProbe.Result
    }

    private struct PassSample {
        let processorSeconds: Double
        let timing: PassTiming
    }

    private struct ColdLaunchMeasurement {
        let beganAt: UInt64
        let usageBefore: Usage
        let probe: UIResourceMainRunLoopProbe
    }

    private struct ManifestContext {
        let identity: UIBenchmarkRevisionIdentity
        let directory: URL
    }

    private static var coldLaunchMeasurement: ColdLaunchMeasurement?

    /// Starts the app-open clock before model construction or SwiftUI scene creation.
    ///
    /// Beginning from `applicationDidFinishLaunching` would measure an already
    /// constructed, already presented application. The launcher gives every
    /// scenario a fresh process, and this hook is the app-open process's first
    /// MainActor instruction after reading its environment.
    static func beginColdLaunchProbe(environment: [String: String]) {
        let benchmark = YunUIBenchmarkConfiguration.resolve(environment: environment)
        guard
            benchmark.isEnabled,
            UIResourceBenchmarkScenario.resolve(environment: environment) == .appOpen,
            coldLaunchMeasurement == nil,
            applyRequestedStyle(environment: environment)
        else { return }

        let beganAt = DispatchTime.now().uptimeNanoseconds
        let probe = UIResourceMainRunLoopProbe(origin: beganAt)
        BodyCount.reset()
        BodyCount.isCounting = true
        coldLaunchMeasurement = ColdLaunchMeasurement(
            beganAt: beganAt, usageBefore: usage(), probe: probe)
        probe.start()
    }

    /// Source-level compositor sites in the deterministic main-window fixture.
    ///
    /// These are not claimed to be Core Animation render passes. They are the
    /// effect modifiers the real fixture instantiates, logged beside the resource
    /// result so a future layout change cannot silently alter what is compared.
    private struct FixtureComposition {
        let cards = 7
        let pills = 1
        let scrollMasks: Int
        let materialEffects: Int
        let cardShadows: Int
        let movingLyricFills: Int

        init(style: YunStyle, variant: YunUIBenchmarkVariant) {
            scrollMasks = variant == .scrollFadesOff ? 0 : 3
            movingLyricFills = variant == .lyricFillStatic ? 0 : 1
            switch style {
            case .flat:
                materialEffects = 0
                cardShadows = 0
            case .glass:
                let cardMaterials = variant == .cardEffectsOff ? 0 : cards
                let windowMaterial = variant == .windowMaterialOff ? 0 : 1
                // The state pill stays unchanged in the card experiment.
                materialEffects = cardMaterials + windowMaterial + pills
                cardShadows = 0
            }
        }
    }

    private static let lyricFixture = """
        [ti:UI resource benchmark]
        [ar:YunAudio]
        [00:00.00]first moving line
        [00:03.00]second moving line
        [00:06.00]third moving line
        [00:09.00]fourth moving line
        [00:12.00]fifth moving line
        [00:15.00]sixth moving line
        [00:18.00]seventh moving line
        [00:21.00]eighth moving line
        """

    /// The exact six-line lyric shape visible when flow-check section 69
    /// reached its mono-file assertion. The audio file is deliberately absent:
    /// constructing its `AVAudioEngine` would make a UI-only reproduction touch
    /// the system output whose isolation this benchmark is meant to prove.
    private static let section69LyricFixture = """
        [ti:yunaudio-chain]
        [00:00.00]line 0
        [00:01.00]line 1
        [00:02.00]line 2
        [00:03.00]line 3
        [00:04.00]line 4
        [00:05.00]line 5
        """

    /// The same eight lines as the song a person actually puts on.
    ///
    /// Everything measured before this was measured on short Latin lines with
    /// no word times: one row per line, one linear animation, no wrapping. A
    /// real line is twenty-odd characters of Chinese that wraps to two rows,
    /// each row needing its own share of the line's fill, and enhanced word
    /// markers that turn each of those into a key-frame path instead. That is
    /// the case the compositor exists for and the case nothing had ever
    /// pointed a stopwatch at.
    private static let longLyricFixture = """
        [ti:UI resource benchmark, long lines]
        [ar:YunAudio]
        [00:00.00]<00:00.00>原来<00:00.80>年少<00:01.60>心动<00:02.00>是逆行在<00:02.60>一场雨季
        [00:03.00]<00:03.00>注定了<00:03.90>无法<00:04.50>走进<00:05.10>同一个<00:05.70>晴天里
        [00:06.00]<00:06.00>可<00:06.30>偏偏<00:06.90>时光的<00:07.50>橡皮<00:08.10>擦去很多
        [00:09.00]<00:09.00>却<00:09.40>放过<00:10.00>你<00:10.40>姓名<00:11.00>而我还在原地
        [00:12.00]<00:12.00>原来<00:12.60>有些<00:13.20>相遇<00:13.80>明明<00:14.40>知道会分离
        [00:15.00]<00:15.00>再<00:15.40>重来<00:16.00>我<00:16.40>依然有<00:17.00>选择你的勇气
        [00:18.00]<00:18.00>只可惜<00:18.90>青春的<00:19.50>诗句<00:20.10>总有挥散不去
        [00:21.00]<00:21.00>的<00:21.30>叹息<00:21.90>还有<00:22.50>那年夏天的<00:23.40>雨季
        """

    static func run(model: RouterModel) async -> Bool {
        guard ProcessInfo.processInfo.environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil else {
            report("UI benchmark refused: YUNAUDIO_SCREENSHOT_NO_AUDIO is required")
            return false
        }
        let benchmark = YunUIBenchmarkConfiguration.process
        guard benchmark.isEnabled else {
            report("UI benchmark refused: its guarded environment is incomplete")
            return false
        }
        guard let variant = benchmark.requestedVariant else {
            let choices = YunUIBenchmarkVariant.allCases.map(\.rawValue).joined(separator: ", ")
            report(
                "UI benchmark refused: unknown variant \(benchmark.requestedName); "
                    + "choose \(choices)")
            return false
        }
        let environment = ProcessInfo.processInfo.environment
        guard let scenario = UIResourceBenchmarkScenario.resolve(environment: environment)
        else {
            let choices = UIResourceBenchmarkScenario.allCases.map(\.rawValue)
                .joined(separator: ", ")
            report(
                "UI benchmark refused: unknown scenario "
                    + "\(environment["YUNAUDIO_UI_BENCHMARK_SCENARIO"] ?? ""); "
                    + "choose \(choices)")
            return false
        }
        guard scenario == .standard || scenario == .windowMovement || variant == .full else {
            report(
                "UI benchmark refused: named scenarios require "
                    + "the production drawing variant")
            return false
        }
        guard
            let window = NSApp.windows.first(where: {
                $0.title == "YunAudio"
            })
        else {
            report("UI benchmark refused: the main window does not exist")
            return false
        }

        let requestedStyle =
            environment["YUNAUDIO_UI_BENCHMARK_STYLE"] ?? "current"
        guard applyRequestedStyle(environment: environment) else {
            report("UI benchmark refused: style must be current, flat, or glass")
            return false
        }
        let requested = environment["YUNAUDIO_UI_BENCHMARK_SECONDS"].flatMap(Double.init) ?? 4
        guard requested.isFinite, requested > 0 else {
            report("UI benchmark refused: duration must be a positive finite number")
            return false
        }
        let movingSeconds = max(4, min(60, requested))
        guard scenario == .standard || manifestContext(environment: environment) != nil else {
            report("UI benchmark refused: the canonical run-group identity is incomplete")
            return false
        }
        report(
            "UI benchmark fresh process \(getpid()), style \(requestedStyle), "
                + "variant \(variant.rawValue), scenario \(scenario.rawValue)")

        if scenario == .appOpen {
            return await measureColdAppOpen(
                model: model,
                window: window,
                seconds: movingSeconds,
                environment: environment,
                variant: variant)
        }
        if scenario == .panelClosed {
            return await measureClosedPanel(
                model: model,
                window: window,
                seconds: movingSeconds,
                environment: environment,
                variant: variant)
        }
        if scenario == .windowMovement {
            return await measureWindowMovement(
                model: model,
                window: window,
                seconds: movingSeconds,
                environment: environment,
                variant: variant)
        }

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "YunAudio-ui-benchmark-\(getpid()).lrc")
        // Off by default, so every figure recorded before this still means
        // what it meant.
        let usesLongLines = environment["YUNAUDIO_UI_BENCHMARK_LYRICS"] == "long"
        guard scenario != .section69 || !usesLongLines else {
            report("UI benchmark refused: section-69 owns its exact six-line lyric fixture")
            return false
        }
        let lyricText =
            scenario == .section69
            ? section69LyricFixture : (usesLongLines ? longLyricFixture : lyricFixture)
        report(
            "UI benchmark lyric lines "
                + (scenario == .section69
                    ? "section-69 exact" : (usesLongLines ? "long, word-timed" : "short")))
        do {
            try lyricText.write(to: fixture, atomically: true, encoding: .utf8)
        } catch {
            report("UI benchmark could not write its lyric fixture: \(error)")
            return false
        }
        defer {
            model.closeWords()
            try? FileManager.default.removeItem(at: fixture)
        }

        // The render fixture supplies a representative mixer and two score
        // rows. Opening a hand-run lyric afterwards prevents Apple events:
        // every position below is local TrackClock arithmetic.
        model.prepareForRendering(refreshesApplications: false)
        guard model.openWords(at: fixture) else {
            report("UI benchmark could not read its lyric fixture")
            return false
        }
        model.runWords()
        model.inspectorTab = .singing
        window.makeKeyAndOrderFront(nil)
        // Optional, and off by default so that every number recorded before
        // this still means what it meant. With it on, the stage is open and
        // drawing beside the inspector, which is what the singing features
        // actually cost.
        let measuresTheStage =
            scenario == .ktvStage
            || environment["YUNAUDIO_UI_BENCHMARK_STAGE"] == "1"
        guard scenario != .section69 || !measuresTheStage else {
            report("UI benchmark refused: section-69 requires the KTV stage to stay closed")
            return false
        }
        if measuresTheStage {
            // Left in front deliberately. A window the window server has
            // covered gets no updates, so re-fronting the inspector would
            // measure a stage that is not drawing and report it as cheap.
            KTVWindow.open(model: model)
        }
        let measuredWindow = measuresTheStage ? (KTVWindow.window ?? window) : window
        defer {
            if measuresTheStage { KTVWindow.close() }
        }
        report("UI benchmark ktv stage \(measuresTheStage ? "open" : "closed")")
        if scenario == .section69 { model.stopWords() }
        await settle(for: 1)
        guard fixtureIsIsolated(model) else { return false }

        switch scenario {
        case .standard:
            break
        case .appOpen, .panelClosed, .windowMovement:
            preconditionFailure("single-boundary scenarios return before lyric setup")
        case .section69:
            break
        case .ktvStage:
            guard KTVWindow.isVisible, model.isKTVWindowOpen else {
                report("UI benchmark refused: KTV-stage fixture changed")
                return false
            }
        }

        if scenario == .section69 {
            guard
                !KTVWindow.isVisible,
                !model.isKTVWindowOpen,
                model.canTransposeSong,
                !model.canCancelLeadVocal,
                model.lyricPlaybackAnchor?.isPlaying == false,
                model.nowPlaying?.isPlaying == false
            else {
                report(
                    "UI benchmark refused: section-69 no longer has a closed stage, "
                        + "key controls and no centre-cancel control")
                return false
            }
            report(
                "UI benchmark section-69 boundary closed stage, key controls visible, "
                    + "centre cancellation absent, no AVAudioEngine")
        }

        let composition = FixtureComposition(style: YunTheme.shared.style, variant: variant)
        report(
            "UI benchmark composition cards \(composition.cards), "
                + "pills \(composition.pills), scroll masks \(composition.scrollMasks), "
                + "material effects \(composition.materialEffects), "
                + "card shadows \(composition.cardShadows), "
                + "moving lyric fills \(composition.movingLyricFills)")

        // A compositor keeps moving without a SwiftUI update, so merely
        // withholding the twenty-hertz model pump is no longer a static pass.
        // Pause explicitly and make the baseline mean the same thing for the
        // production, frozen and legacy variants.
        let staticSeconds = scenario == .section69 ? max(10, movingSeconds) : 4.0
        let livenessOrigin = DispatchTime.now().uptimeNanoseconds

        model.stopWords()
        await settle(for: 0.15)
        let seeded = usage()
        BodyCount.reset()
        BodyCount.isCounting = true
        let staticBefore = usage()
        let staticProbe = UIResourceMainRunLoopProbe(origin: livenessOrigin)
        staticProbe.start()
        let staticBegan = monotonicSeconds()
        await settle(for: staticSeconds)
        let staticWall = monotonicSeconds() - staticBegan
        let staticDelivery = await staticProbe.finish()
        let staticAfter = usage()
        BodyCount.isCounting = false
        let staticBodies = BodyCount.counts
        let staticTiming = PassTiming(
            wallSeconds: staticWall,
            maximumTaskSchedulingLateness: max(0, staticWall - staticSeconds),
            mainRunLoopDelivery: staticDelivery)

        model.runWords(from: 0)
        guard
            await verifyLyricControl(
                in: measuredWindow, variant: variant, model: model)
        else {
            return false
        }
        model.runWords(from: 0)
        await settle(for: 0.15)
        BodyCount.reset()
        BodyCount.isCounting = true
        report("UI benchmark counted moving pass started")
        let countedBefore = usage()
        let countedTiming = await advance(
            model, for: movingSeconds, livenessOrigin: livenessOrigin,
            exercisesModel: true)
        let countedAfter = usage()
        BodyCount.isCounting = false
        let movingBodies = BodyCount.counts

        var movingSamples: [PassSample] = []
        var movingAfter = countedAfter
        for sample in 1...3 {
            model.runWords(from: 0)
            await settle(for: 0.15)
            report("UI benchmark uncounted moving pass \(sample) started")
            let movingBefore = usage()
            let timing = await advance(
                model, for: movingSeconds, livenessOrigin: livenessOrigin,
                exercisesModel: true)
            movingAfter = usage()
            movingSamples.append(
                PassSample(
                    processorSeconds: movingAfter.processorSeconds
                        - movingBefore.processorSeconds,
                    timing: timing))
        }

        let staticCPU = staticAfter.processorSeconds - staticBefore.processorSeconds
        let countedCPU = countedAfter.processorSeconds - countedBefore.processorSeconds
        let sortedMoving = movingSamples.sorted { $0.processorSeconds < $1.processorSeconds }
        let movingSample = sortedMoving[sortedMoving.count / 2]
        let movingCPU = movingSample.processorSeconds
        let labelledTimings =
            [("static", staticTiming), ("counted", countedTiming)]
            + movingSamples.enumerated().map { index, sample in
                ("moving-\(index + 1)", sample.timing)
            }
        let worstDelivery = labelledTimings.max {
            $0.1.mainRunLoopDelivery.maximumSeconds
                < $1.1.mainRunLoopDelivery.maximumSeconds
        }
        let maximumDeliveryLatency =
            worstDelivery?.1.mainRunLoopDelivery.maximumSeconds ?? .infinity
        let maximumTaskSchedulingLateness =
            labelledTimings.map(\.1.maximumTaskSchedulingLateness).max() ?? 0
        let mainActorEvidence = MainActorScenarioEvidence.combine(
            labelledTimings.map(\.1.mainRunLoopDelivery.evidence))
        let mainActorMeetsBudget = admitsRequiredLatency(mainActorEvidence)
        report(
            "UI benchmark uncounted samples "
                + movingSamples.map {
                    String(format: "%.0f ms", $0.processorSeconds * 1_000)
                }
                .joined(separator: ", ")
                + "; median selected")
        report(
            String(
                format:
                    "UI benchmark static %.0f ms / %.0f s (%.2f%% core), moving %.0f ms / %.0f s (%.2f%% core), delta %.0f ms",
                staticCPU * 1_000, staticSeconds, staticCPU / staticSeconds * 100,
                movingCPU * 1_000, movingSeconds, movingCPU / movingSeconds * 100,
                (movingCPU - staticCPU * movingSeconds / staticSeconds) * 1_000))
        report(
            String(
                format:
                    "UI benchmark timing static %.3f / %.0f s, moving %.3f / %.0f s",
                staticWall, staticSeconds, movingSample.timing.wallSeconds, movingSeconds,
            ))
        if let worstDelivery {
            report(
                String(
                    format:
                        "UI benchmark main-run-loop delivery maximum %.3f s at +%.3f s in %@ (%d samples); task scheduling lateness %.3f s diagnostic only",
                    worstDelivery.1.mainRunLoopDelivery.maximumSeconds,
                    worstDelivery.1.mainRunLoopDelivery.maximumAtSeconds,
                    worstDelivery.0,
                    worstDelivery.1.mainRunLoopDelivery.samples,
                    maximumTaskSchedulingLateness))
        }
        reportMainActorEvidence(mainActorEvidence)
        report(
            String(
                format:
                    "UI benchmark counted moving %.0f ms, instrumentation delta %.0f ms",
                countedCPU * 1_000, (countedCPU - movingCPU) * 1_000))
        model.stopWords()
        await settle(for: 1)
        let settledAfter = usage()
        report(
            "UI benchmark footprint seeded \(mebibytes(seeded.footprintBytes)) MiB, "
                + "moving immediate \(mebibytes(movingAfter.footprintBytes)) MiB, "
                + "final \(mebibytes(settledAfter.footprintBytes)) MiB")
        reportBodies("static", counts: staticBodies, seconds: staticSeconds)
        reportBodies("moving", counts: movingBodies, seconds: movingSeconds)
        if scenario == .section69 {
            for name in ["MainWindow", "SingingPanel", "KTVTransportPanel", "KTVStage"] {
                report(
                    "UI benchmark section-69 body \(name) static "
                        + "\(staticBodies[name, default: 0]), moving "
                        + "\(movingBodies[name, default: 0])")
            }
        }

        let sectionMeetsBudget =
            scenario != .section69
            || UIResourceBenchmarkBudget.admitsSection69(
                staticProcessorSeconds: staticCPU,
                staticWallSeconds: staticWall,
                plannedStaticSeconds: staticSeconds,
                movingProcessorSeconds: movingCPU,
                movingWallSeconds: movingSample.timing.wallSeconds,
                plannedMovingSeconds: movingSeconds,
                mainRunLoopDeliveryLatency: maximumDeliveryLatency)
        if !sectionMeetsBudget {
            report(
                "UI benchmark failed: section-69 exceeded 5% static core, 10% moving "
                    + "core, 2.0 s pass overrun or 0.10 s main-run-loop delivery latency")
        }
        return recordManifest(
            scenario: scenario,
            seconds: movingSeconds,
            variant: variant,
            mainActor: mainActorEvidence,
            resources: resourcePhases(
                staticCPU: staticCPU,
                staticWall: staticWall,
                staticAfter: staticAfter,
                staticBodies: staticBodies,
                countedCPU: countedCPU,
                countedTiming: countedTiming,
                countedAfter: countedAfter,
                countedBodies: movingBodies,
                movingCPU: movingCPU,
                movingWall: movingSample.timing.wallSeconds,
                movingAfter: movingAfter),
            passed: sectionMeetsBudget && mainActorMeetsBudget,
            environment: environment)
    }

    /// Completes the probe which began before `RouterModel` existed.
    private static func measureColdAppOpen(
        model: RouterModel,
        window: NSWindow,
        seconds: Double,
        environment: [String: String],
        variant: YunUIBenchmarkVariant
    ) async -> Bool {
        guard let cold = coldLaunchMeasurement else {
            report(
                "UI benchmark refused: app-open probe did not begin before model construction")
            return false
        }
        coldLaunchMeasurement = nil
        window.makeKeyAndOrderFront(nil)
        await settle(for: seconds)
        let delivery = await cold.probe.finish()
        let after = usage()
        BodyCount.isCounting = false
        let bodies = BodyCount.counts
        let endedAt = DispatchTime.now().uptimeNanoseconds
        let wallSeconds = Double(endedAt - cold.beganAt) / 1e9
        let boundaryIsExact =
            window.isVisible
            && !KTVWindow.isVisible
            && !model.isKTVWindowOpen
            && !model.isRunning
            && model.inputDevices.isEmpty
            && model.outputDevices.isEmpty
            && model.availableApps.isEmpty
            && model.appsRefreshedAt == nil
        let resources = [
            UIBenchmarkResourcePhase(
                name: "cold-app-open",
                processorSeconds: max(
                    0, after.processorSeconds - cold.usageBefore.processorSeconds),
                wallSeconds: wallSeconds,
                footprintBytes: after.footprintBytes,
                bodyEvaluations: bodies)
        ]
        reportSingleBoundary(
            "app-open", evidence: delivery.evidence, resources: resources,
            exact: boundaryIsExact)
        let passed = boundaryIsExact && admitsRequiredLatency(delivery.evidence)
        return recordManifest(
            scenario: .appOpen,
            seconds: seconds,
            variant: variant,
            mainActor: delivery.evidence,
            resources: resources,
            passed: passed,
            environment: environment)
    }

    /// Measures a main window which has actually left the WindowServer scene.
    private static func measureClosedPanel(
        model: RouterModel,
        window: NSWindow,
        seconds: Double,
        environment: [String: String],
        variant: YunUIBenchmarkVariant
    ) async -> Bool {
        KTVWindow.close()
        model.isSingingVisible = false
        model.inspectorTab = .sound
        window.orderOut(nil)
        await settle(for: 0.15)
        guard !window.isVisible, !KTVWindow.isVisible, !model.isKTVWindowOpen else {
            report("UI benchmark refused: panel-closed window remained in the visible scene")
            return false
        }

        let beganAt = DispatchTime.now().uptimeNanoseconds
        let before = usage()
        BodyCount.reset()
        BodyCount.isCounting = true
        let probe = UIResourceMainRunLoopProbe(origin: beganAt)
        probe.start()
        await settle(for: seconds)
        let delivery = await probe.finish()
        let after = usage()
        BodyCount.isCounting = false
        let bodies = BodyCount.counts
        let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - beganAt) / 1e9
        let boundaryIsExact =
            !window.isVisible
            && !KTVWindow.isVisible
            && !model.isKTVWindowOpen
            && !model.isRunning
            && model.inputDevices.isEmpty
            && model.outputDevices.isEmpty
            && model.availableApps.isEmpty
            && model.appsRefreshedAt == nil
        let resources = [
            UIBenchmarkResourcePhase(
                name: "panel-order-out",
                processorSeconds: max(0, after.processorSeconds - before.processorSeconds),
                wallSeconds: wallSeconds,
                footprintBytes: after.footprintBytes,
                bodyEvaluations: bodies)
        ]
        reportSingleBoundary(
            "panel-closed", evidence: delivery.evidence, resources: resources,
            exact: boundaryIsExact)
        let passed = boundaryIsExact && admitsRequiredLatency(delivery.evidence)
        return recordManifest(
            scenario: .panelClosed,
            seconds: seconds,
            variant: variant,
            mainActor: delivery.evidence,
            resources: resources,
            passed: passed,
            environment: environment)
    }

    /// Moves the real main window at ProMotion cadence after launch has settled.
    ///
    /// A static view benchmark cannot see the compositor work paid only while
    /// somebody drags a window. Moving the AppKit window itself preserves the
    /// production SwiftUI tree and records both the independent 1 ms delivery
    /// probe and whether the 120 Hz movement schedule falls behind.
    private static func measureWindowMovement(
        model: RouterModel,
        window: NSWindow,
        seconds: Double,
        environment: [String: String],
        variant: YunUIBenchmarkVariant
    ) async -> Bool {
        if variant == .windowShadowOff { window.hasShadow = false }
        defer {
            if variant == .windowShadowOff { window.hasShadow = true }
        }
        window.makeKeyAndOrderFront(nil)
        await settle(for: 1)

        let originalOrigin = window.frame.origin
        let cadence = 1.0 / 120.0
        let requestedMoves = max(1, Int((seconds * 120).rounded()))
        let beganAt = DispatchTime.now().uptimeNanoseconds
        let before = usage()
        BodyCount.reset()
        BodyCount.isCounting = true
        let probe = UIResourceMainRunLoopProbe(origin: beganAt)
        probe.start()
        var movementLateness: [UInt64] = []
        movementLateness.reserveCapacity(requestedMoves)
        let clock = ContinuousClock()
        let began = clock.now

        for index in 0..<requestedMoves {
            let target = began + .nanoseconds(Int64(Double(index) * cadence * 1e9))
            try? await clock.sleep(until: target, tolerance: .zero)
            let actual = clock.now
            let late = target.duration(to: actual)
            let lateSeconds = max(
                0,
                Double(late.components.seconds)
                    + Double(late.components.attoseconds) / 1e18)
            movementLateness.append(UInt64(lateSeconds * 1e9))
            let phase = Double(index) / 120.0
            window.setFrameOrigin(
                NSPoint(
                    x: originalOrigin.x + CGFloat(sin(phase * 2 * .pi) * 48),
                    y: originalOrigin.y + CGFloat(cos(phase * 2 * .pi) * 32)))
        }
        window.setFrameOrigin(originalOrigin)

        let delivery = await probe.finish()
        let after = usage()
        BodyCount.isCounting = false
        let bodies = BodyCount.counts
        let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - beganAt) / 1e9
        let movement = MainActorLatencyDistribution(nanoseconds: movementLateness)
        let boundaryIsExact =
            window.isVisible
            && !KTVWindow.isVisible
            && !model.isKTVWindowOpen
            && !model.isRunning
            && movement.samples == requestedMoves
        let resources = [
            UIBenchmarkResourcePhase(
                name: "window-movement",
                processorSeconds: max(0, after.processorSeconds - before.processorSeconds),
                wallSeconds: wallSeconds,
                footprintBytes: after.footprintBytes,
                bodyEvaluations: bodies)
        ]
        reportSingleBoundary(
            "window-movement", evidence: delivery.evidence, resources: resources,
            exact: boundaryIsExact)
        report(
            String(
                format:
                    "UI benchmark window movement %d/%d, lateness p50 %.3f ms, p99 %.3f ms, max %.3f ms",
                movement.samples, requestedMoves,
                movement.p50Seconds * 1_000,
                movement.p99Seconds * 1_000,
                movement.maximumSeconds * 1_000))
        let movementMeetsBudget = UIResourceBenchmarkBudget.admitsWindowMovement(
            movement, mainActor: delivery.evidence)
        if !movementMeetsBudget {
            report(
                "UI benchmark failed: 120 Hz window movement exceeded one-frame p99 "
                    + "or four-frame movement/MainActor containment")
        }
        let passed =
            boundaryIsExact
            && movementMeetsBudget
        return recordManifest(
            scenario: .windowMovement,
            seconds: seconds,
            variant: variant,
            mainActor: delivery.evidence,
            resources: resources,
            passed: passed,
            environment: environment)
    }

    private static func resourcePhases(
        staticCPU: Double,
        staticWall: Double,
        staticAfter: Usage,
        staticBodies: [String: Int],
        countedCPU: Double,
        countedTiming: PassTiming,
        countedAfter: Usage,
        countedBodies: [String: Int],
        movingCPU: Double,
        movingWall: Double,
        movingAfter: Usage
    ) -> [UIBenchmarkResourcePhase] {
        [
            UIBenchmarkResourcePhase(
                name: "static",
                processorSeconds: max(0, staticCPU),
                wallSeconds: staticWall,
                footprintBytes: staticAfter.footprintBytes,
                bodyEvaluations: staticBodies),
            UIBenchmarkResourcePhase(
                name: "moving-median",
                processorSeconds: max(0, movingCPU),
                wallSeconds: movingWall,
                footprintBytes: movingAfter.footprintBytes,
                bodyEvaluations: [:]),
            UIBenchmarkResourcePhase(
                name: "moving-instrumented",
                processorSeconds: max(0, countedCPU),
                wallSeconds: countedTiming.wallSeconds,
                footprintBytes: countedAfter.footprintBytes,
                bodyEvaluations: countedBodies),
        ]
    }

    private static func reportSingleBoundary(
        _ name: String,
        evidence: MainActorScenarioEvidence,
        resources: [UIBenchmarkResourcePhase],
        exact: Bool
    ) {
        let resource = resources[0]
        report(
            String(
                format:
                    "UI benchmark %@ boundary %@, %.0f ms CPU / %.3f s, %.1f MiB",
                name, exact ? "exact" : "changed",
                resource.processorSeconds * 1_000, resource.wallSeconds,
                Double(resource.footprintBytes) / 1_048_576))
        reportMainActorEvidence(evidence)
        reportBodies(name, counts: resource.bodyEvaluations, seconds: resource.wallSeconds)
    }

    private static func reportMainActorEvidence(_ evidence: MainActorScenarioEvidence) {
        report(
            String(
                format:
                    "UI benchmark 1 ms producer p50 %.3f ms, p99 %.3f ms, max %.3f ms; misses %d",
                evidence.producer.p50Seconds * 1_000,
                evidence.producer.p99Seconds * 1_000,
                evidence.producer.maximumSeconds * 1_000,
                evidence.producerMisses))
        report(
            String(
                format:
                    "UI benchmark MainActor distribution p50 %.3f ms, p99 %.3f ms, max %.3f ms; coverage %d/%d (%.3f%%)",
                evidence.delivery.p50Seconds * 1_000,
                evidence.delivery.p99Seconds * 1_000,
                evidence.delivery.maximumSeconds * 1_000,
                evidence.deliveredSamples,
                evidence.expectedSamples,
                evidence.minimumSampleCoverage * 100))
    }

    private static func admitsRequiredLatency(_ evidence: MainActorScenarioEvidence) -> Bool {
        let containment =
            evidence.delivery.maximumSeconds
            <= UIResourceBenchmarkBudget.maximumMainRunLoopDeliveryLatency
        let distribution = UIResourceBenchmarkBudget.admitsMainActor(evidence)
        if !containment {
            report("UI benchmark failed: the 100 ms containment watchdog fired")
        }
        if !distribution {
            report(
                "UI benchmark failed: 1 ms coverage or MainActor p50 0.5 ms, "
                    + "p99 2 ms, max 8 ms gate failed")
        }
        return containment && distribution
    }

    private static func applyRequestedStyle(environment: [String: String]) -> Bool {
        switch environment["YUNAUDIO_UI_BENCHMARK_STYLE"] ?? "current" {
        case "flat":
            YunTheme.shared.style = .flat
        case "glass":
            YunTheme.shared.style = .glass
        case "current":
            break
        default:
            return false
        }
        return true
    }

    private static func manifestContext(
        environment: [String: String]
    ) -> ManifestContext? {
        guard
            let identity = UIBenchmarkRevisionIdentity.resolve(environment: environment),
            let path = environment["YUNAUDIO_UI_BENCHMARK_MANIFEST_DIR"],
            !path.isEmpty
        else { return nil }
        return ManifestContext(
            identity: identity, directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func recordManifest(
        scenario: UIResourceBenchmarkScenario,
        seconds: Double,
        variant: YunUIBenchmarkVariant,
        mainActor: MainActorScenarioEvidence,
        resources: [UIBenchmarkResourcePhase],
        passed: Bool,
        environment: [String: String]
    ) -> Bool {
        guard scenario != .standard else { return passed }
        guard let context = manifestContext(environment: environment) else {
            report("UI benchmark failed: canonical manifest context disappeared")
            return false
        }
        let manifest = UIBenchmarkScenarioManifest(
            identity: context.identity,
            scenario: scenario,
            processIdentifier: getpid(),
            style: YunTheme.shared.style.rawValue,
            variant: variant.rawValue,
            requestedSeconds: seconds,
            mainActor: mainActor,
            resources: resources,
            passed: passed)
        do {
            let outcome = try UIBenchmarkManifestStore.write(manifest, to: context.directory)
            switch outcome {
            case .recorded:
                report("UI benchmark manifest recorded \(scenario.rawValue)")
            case .aggregated(let url):
                report("UI benchmark canonical aggregate \(url.path)")
            }
            return passed
        } catch {
            report("UI benchmark failed to record canonical evidence: \(error)")
            return false
        }
    }

    /// Proves that each A/B control changes the intended moving boundary.
    ///
    /// The production assertion reads the presentation layer, not the model
    /// layer: a CABasicAnimation can be installed with the right endpoints and
    /// still fail to reach the window's compositor tree.
    private static func verifyLyricControl(
        in window: NSWindow,
        variant: YunUIBenchmarkVariant,
        model: RouterModel
    ) async -> Bool {
        switch variant {
        case .lyricFillLegacy:
            guard findCompositedLyricView(in: window.contentView) == nil else {
                report("UI benchmark refused: legacy lyrics still contain a compositor leaf")
                return false
            }
            report("UI benchmark lyric control legacy Observation renderer")
            return true
        default:
            guard let view = findCompositedLyricView(in: window.contentView) else {
                report("UI benchmark refused: compositor lyric leaf is missing")
                return false
            }
            await settle(for: 0.06)
            guard let before = view.presentationProgress() else {
                report("UI benchmark refused: lyric presentation layer is unavailable")
                return false
            }
            await settle(for: 0.22)
            guard let after = view.presentationProgress() else {
                report("UI benchmark refused: lyric presentation layer disappeared")
                return false
            }
            let delta = after - before
            if variant == .lyricFillStatic {
                guard abs(delta) < 0.002 else {
                    report(
                        String(
                            format:
                                "UI benchmark refused: frozen lyric presentation moved %.4f",
                            delta))
                    return false
                }
                report("UI benchmark lyric control static presentation stayed fixed")
            } else {
                guard delta > 0.03, model.lyricPlaybackAnchor?.isPlaying == true else {
                    report(
                        String(
                            format:
                                "UI benchmark refused: production lyric presentation moved %.4f",
                            delta))
                    return false
                }
                report(
                    String(
                        format:
                            "UI benchmark lyric presentation advanced %.4f without an Observation frame",
                        delta))
            }
            return true
        }
    }

    private static func findCompositedLyricView(in root: NSView?) -> CompositedLyricView? {
        guard let root else { return nil }
        if let lyric = root as? CompositedLyricView { return lyric }
        for child in root.subviews {
            if let lyric = findCompositedLyricView(in: child) { return lyric }
        }
        return nil
    }

    /// Verifies the state whose compositor counts are logged above.
    ///
    /// App rows are the important boundary: a `.task` used to enumerate HAL
    /// after the fixture explicitly declined application refresh, making the
    /// one-second settle period machine-dependent.
    private static func fixtureIsIsolated(_ model: RouterModel) -> Bool {
        let applicationList = model.appListing(limit: .max)
        let hasNoApplications =
            model.availableApps.isEmpty
            && applicationList.applications.isEmpty
            && applicationList.background.isEmpty
            && model.appsRefreshedAt == nil
        guard hasNoApplications else {
            report(
                "UI benchmark refused: application discovery escaped the fixture "
                    + "(available \(model.availableApps.count), "
                    + "refreshed \(model.appsRefreshedAt != nil))")
            return false
        }

        let routes = model.activeRoutes
        let hasSyntheticRoutes =
            routes.count == 2
            && routes.map(\.source.deviceUID) == ["preview-source", "preview-source"]
            && routes.map(\.source.channel) == [0, 0]
            && routes.map(\.destination.deviceUID) == [
                "preview-destination", "preview-destination",
            ]
            && routes.map(\.destination.channel) == [0, 1]
            && model.routeGains == [1.0, 0.7]
            && model.routeMutes == [false, true]
            && model.levels == [0.28, 0.0]
        let hasExpectedTree =
            model.isRunning
            && model.inputDevices.isEmpty
            && model.outputDevices.isEmpty
            && model.selectedSource == nil
            && model.selectedDestination == nil
            && model.buses.isEmpty
            && hasSyntheticRoutes
            && model.inspectorTab == .singing
            && model.nowPlaying != nil
            && model.lyrics != nil
            && StatusPills.pills(for: model).count == 1
        guard hasExpectedTree else {
            report(
                "UI benchmark refused: main-window fixture no longer has "
                    + "7 cards, 3 columns and 1 status pill "
                    + "(running \(model.isRunning), inputs \(model.inputDevices.count), "
                    + "outputs \(model.outputDevices.count), "
                    + "source \(model.selectedSource != nil), "
                    + "destination \(model.selectedDestination != nil), "
                    + "buses \(model.buses.count), routes \(routes.count), "
                    + "tab \(model.inspectorTab), track \(model.nowPlaying != nil), "
                    + "lyrics \(model.lyrics != nil), "
                    + "pills \(StatusPills.pills(for: model).count))")
            return false
        }
        return true
    }

    private static func advance(
        _ model: RouterModel,
        for seconds: Double,
        livenessOrigin: UInt64,
        exercisesModel: Bool = true
    ) async -> PassTiming {
        let frames = Int(seconds * 20)
        let began = DispatchTime.now().uptimeNanoseconds
        let probe = UIResourceMainRunLoopProbe(origin: livenessOrigin)
        probe.start()
        var maximumTaskSchedulingLateness: UInt64 = 0
        for frame in 1...frames {
            if exercisesModel { model.refreshNowPlaying() }
            let deadline = began + UInt64(frame) * 50_000_000
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                try? await Task.sleep(nanoseconds: deadline - now)
            } else {
                maximumTaskSchedulingLateness = max(
                    maximumTaskSchedulingLateness, now - deadline)
            }
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        let expectedEnd = began + UInt64(frames) * 50_000_000
        if ended > expectedEnd {
            maximumTaskSchedulingLateness = max(
                maximumTaskSchedulingLateness, ended - expectedEnd)
        }
        let delivery = await probe.finish()
        return PassTiming(
            wallSeconds: Double(ended - began) / 1e9,
            maximumTaskSchedulingLateness: Double(maximumTaskSchedulingLateness) / 1e9,
            mainRunLoopDelivery: delivery)
    }

    private static func reportBodies(
        _ phase: String,
        counts: [String: Int],
        seconds: Double
    ) {
        let prefix = phase == "moving" ? "UI benchmark body" : "UI benchmark \(phase) body"
        if counts.isEmpty {
            report("\(prefix) evaluations none")
            return
        }
        for (name, count) in counts.sorted(by: { $0.value > $1.value }) {
            report(
                String(
                    format: "\(prefix) %-16s %4d (%.2f Hz)",
                    (name as NSString).utf8String!, count, Double(count) / seconds))
        }
    }

    private static func settle(for seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    private static func usage() -> Usage {
        var resource = rusage()
        let processor: Double
        if getrusage(RUSAGE_SELF, &resource) == 0 {
            let user =
                Double(resource.ru_utime.tv_sec) + Double(resource.ru_utime.tv_usec) / 1e6
            let system =
                Double(resource.ru_stime.tv_sec) + Double(resource.ru_stime.tv_usec) / 1e6
            processor = user + system
        } else {
            processor = 0
        }

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Usage(
            processorSeconds: processor,
            footprintBytes: result == KERN_SUCCESS ? info.phys_footprint : 0)
    }

    private static func mebibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
