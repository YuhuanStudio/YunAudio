import Foundation
import Testing
import YunDesign

@testable import YunAudioApp

@Suite("UI resource benchmark boundary")
struct UIResourceBenchmarkTests {
    @Test("section 69 is an explicit deterministic scenario")
    func section69ScenarioIsExplicit() {
        #expect(UIResourceBenchmarkScenario.resolve(environment: [:]) == .standard)
        #expect(
            UIResourceBenchmarkScenario.resolve(environment: [
                "YUNAUDIO_UI_BENCHMARK_SCENARIO": "app-open"
            ]) == .appOpen)
        #expect(
            UIResourceBenchmarkScenario.resolve(environment: [
                "YUNAUDIO_UI_BENCHMARK_SCENARIO": "panel-closed"
            ]) == .panelClosed)
        #expect(
            UIResourceBenchmarkScenario.resolve(environment: [
                "YUNAUDIO_UI_BENCHMARK_SCENARIO": "window-movement"
            ]) == .windowMovement)
        #expect(
            UIResourceBenchmarkScenario.resolve(environment: [
                "YUNAUDIO_UI_BENCHMARK_SCENARIO": "section-69"
            ]) == .section69)
        #expect(
            UIResourceBenchmarkScenario.resolve(environment: [
                "YUNAUDIO_UI_BENCHMARK_SCENARIO": "unknown"
            ]) == nil)
        #expect(
            UIResourceBenchmarkScenario.resolve(environment: [
                "YUNAUDIO_UI_BENCHMARK_SCENARIO": "ktv-stage"
            ]) == .ktvStage)
        #expect(UIResourceBenchmarkScenario.allCases.count == 6)
    }

    @Test("section 69 rejects the measured storm but admits a healthy layout")
    func section69HasNumericBudget() {
        #expect(
            UIResourceBenchmarkBudget.admitsSection69(
                staticProcessorSeconds: 0.08,
                staticWallSeconds: 10,
                plannedStaticSeconds: 10,
                movingProcessorSeconds: 0.28,
                movingWallSeconds: 10,
                plannedMovingSeconds: 10,
                mainRunLoopDeliveryLatency: 0.02))
        #expect(
            !UIResourceBenchmarkBudget.admitsSection69(
                staticProcessorSeconds: 1.4,
                staticWallSeconds: 10,
                plannedStaticSeconds: 10,
                movingProcessorSeconds: 0.28,
                movingWallSeconds: 10,
                plannedMovingSeconds: 10,
                mainRunLoopDeliveryLatency: 0.02))
        #expect(
            !UIResourceBenchmarkBudget.admitsSection69(
                staticProcessorSeconds: 0.08,
                staticWallSeconds: 12.1,
                plannedStaticSeconds: 10,
                movingProcessorSeconds: 0.28,
                movingWallSeconds: 10,
                plannedMovingSeconds: 10,
                mainRunLoopDeliveryLatency: 0.02))
        #expect(
            !UIResourceBenchmarkBudget.admitsSection69(
                staticProcessorSeconds: 0.08,
                staticWallSeconds: 10,
                plannedStaticSeconds: 10,
                movingProcessorSeconds: 0.28,
                movingWallSeconds: 10,
                plannedMovingSeconds: 10,
                mainRunLoopDeliveryLatency: 0.101))
    }

    @Test("the MainActor distribution rejects an injected nine millisecond stall")
    func mainActorDistributionGate() {
        let healthy = MainActorLatencyDistribution(
            nanoseconds: [UInt64](repeating: 200_000, count: 1_000))
        #expect(healthy.samples == 1_000)
        #expect(healthy.p50Seconds == 0.0002)
        #expect(healthy.p99Seconds == 0.0002)
        #expect(healthy.maximumSeconds == 0.0002)
        #expect(UIResourceBenchmarkBudget.admitsMainActor(healthy))

        var stalled = [UInt64](repeating: 200_000, count: 999)
        stalled.append(9_000_000)
        let injected = MainActorLatencyDistribution(nanoseconds: stalled)
        #expect(injected.p50Seconds == 0.0002)
        #expect(injected.p99Seconds == 0.0002)
        #expect(injected.maximumSeconds == 0.009)
        #expect(!UIResourceBenchmarkBudget.admitsMainActor(injected))

        let p99Regression = MainActorLatencyDistribution(
            nanoseconds: [UInt64](repeating: 200_000, count: 989)
                + [UInt64](repeating: 2_100_000, count: 11))
        #expect(p99Regression.p99Seconds == 0.0021)
        #expect(!UIResourceBenchmarkBudget.admitsMainActor(p99Regression))
        #expect(
            !UIResourceBenchmarkBudget.admitsMainActor(
                MainActorLatencyDistribution(nanoseconds: [])))
    }

    @Test("the hard distribution boundaries are exact")
    func mainActorDistributionBoundariesAreExact() {
        #expect(
            UIResourceBenchmarkBudget.admitsMainActor(
                MainActorLatencyDistribution(
                    samples: 1, p50Seconds: 0.0005, p99Seconds: 0.002,
                    maximumSeconds: 0.008)))
        #expect(
            !UIResourceBenchmarkBudget.admitsMainActor(
                MainActorLatencyDistribution(
                    samples: 1, p50Seconds: 0.000_501, p99Seconds: 0.002,
                    maximumSeconds: 0.008)))
        #expect(
            !UIResourceBenchmarkBudget.admitsMainActor(
                MainActorLatencyDistribution(
                    samples: 1, p50Seconds: 0.0005, p99Seconds: 0.002_001,
                    maximumSeconds: 0.008)))
        #expect(
            !UIResourceBenchmarkBudget.admitsMainActor(
                MainActorLatencyDistribution(
                    samples: 1, p50Seconds: 0.0005, p99Seconds: 0.002,
                    maximumSeconds: 0.008_001)))
    }

    @Test("window movement uses exact ProMotion frame boundaries")
    func windowMovementFrameBoundariesAreExact() {
        let frame = UIResourceBenchmarkBudget.promotionFrameSeconds
        let movement = MainActorLatencyDistribution(
            samples: 480, p50Seconds: 0.0005, p99Seconds: frame,
            maximumSeconds: frame)
        let delivery = MainActorLatencyDistribution(
            samples: 4_000, p50Seconds: 0.0005, p99Seconds: frame,
            maximumSeconds: frame * 4)
        let accepted = MainActorScenarioEvidence(
            passCount: 1, expectedSamples: 4_000, deliveredSamples: 4_000,
            producerMisses: 0, minimumSampleCoverage: 1,
            producer: delivery, delivery: delivery)

        #expect(UIResourceBenchmarkBudget.admitsWindowMovement(movement, mainActor: accepted))
        #expect(
            UIResourceBenchmarkBudget.admitsWindowMovement(
                MainActorLatencyDistribution(
                    samples: 480, p50Seconds: 0.0005, p99Seconds: frame,
                    maximumSeconds: frame * 4),
                mainActor: accepted))
        #expect(
            !UIResourceBenchmarkBudget.admitsWindowMovement(
                MainActorLatencyDistribution(
                    samples: 480, p50Seconds: 0.0005, p99Seconds: frame,
                    maximumSeconds: frame * 4 + 0.000_001),
                mainActor: accepted))
        #expect(
            !UIResourceBenchmarkBudget.admitsWindowMovement(
                MainActorLatencyDistribution(
                    samples: 480, p50Seconds: 0.0005, p99Seconds: frame + 0.000_001,
                    maximumSeconds: frame + 0.000_001),
                mainActor: accepted))
        #expect(
            !UIResourceBenchmarkBudget.admitsWindowMovement(
                movement,
                mainActor: MainActorScenarioEvidence(
                    passCount: 1, expectedSamples: 4_000, deliveredSamples: 3_959,
                    producerMisses: 41, minimumSampleCoverage: 0.98975,
                    producer: delivery, delivery: delivery)))
    }

    @Test("sample coverage is numeric and producer misses cannot be hidden")
    func sampleCoverageIsFailClosed() {
        let distribution = MainActorLatencyDistribution(
            nanoseconds: [UInt64](repeating: 200_000, count: 990))
        let accepted = MainActorScenarioEvidence(
            passCount: 1,
            expectedSamples: 1_000,
            deliveredSamples: 990,
            producerMisses: 10,
            minimumSampleCoverage: 0.99,
            producer: distribution,
            delivery: distribution)
        #expect(UIResourceBenchmarkBudget.admitsMainActor(accepted))
        #expect(
            !UIResourceBenchmarkBudget.admitsMainActor(
                evidence(accepted, delivered: 989, misses: 11, coverage: 0.989)))
        #expect(
            !UIResourceBenchmarkBudget.admitsMainActor(
                evidence(accepted, delivered: 990, misses: 9, coverage: 0.99)))
        #expect(
            !UIResourceBenchmarkBudget.admitsMainActor(
                evidence(accepted, delivered: 989, misses: 11, coverage: 1)))
    }

    @MainActor
    @Test("a queued delivery observes a deterministic nine millisecond MainActor barrier")
    func queuedDeliveryObservesNineMillisecondBarrier() async {
        let recorder = MainActorDeliveryRecorder(
            origin: DispatchTime.now().uptimeNanoseconds)
        enqueueDeliveryAndBlockMainActor(recorder)
        await withCheckedContinuation { continuation in
            MainRunLoopDelivery.perform { continuation.resume() }
        }

        let observed = recorder.result.distribution
        #expect(observed.samples == 1)
        #expect(observed.maximumSeconds >= 0.009)
        #expect(!UIResourceBenchmarkBudget.admitsMainActor(observed))
    }

    @MainActor
    private func enqueueDeliveryAndBlockMainActor(_ recorder: MainActorDeliveryRecorder) {
        #expect(Thread.isMainThread)
        let enqueued = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let sentAt = DispatchTime.now().uptimeNanoseconds
            MainRunLoopDelivery.perform {
                recorder.record(sentAt: sentAt)
            }
            enqueued.signal()
        }
        #expect(enqueued.wait(timeout: .now() + TestGate.deadlock) == .success)

        Thread.sleep(forTimeInterval: 0.009)
    }

    @Test("canonical evidence requires four revisions and four fresh processes")
    func canonicalManifestRequiresExactRunGroup() throws {
        let identity = revisionIdentity()
        let manifests = zip(
            UIBenchmarkContract.requiredScenarios,
            [Int32(101), 102, 103, 104]
        ).map { scenarioManifest(identity: identity, scenario: $0.0, pid: $0.1) }

        let aggregate = try UIBenchmarkManifestAggregator.validate(manifests).get()
        #expect(aggregate.identity == identity)
        #expect(aggregate.scenarios.map(\.scenario) == UIBenchmarkContract.requiredScenarios)
        #expect(aggregate.scenarios.map(\.processIdentifier) == [101, 102, 103, 104])
        #expect(isFailure(UIBenchmarkManifestAggregator.validate(Array(manifests.dropLast()))))

        var duplicatePID = manifests
        duplicatePID[3] = scenarioManifest(
            identity: identity, scenario: .ktvStage, pid: 103)
        #expect(isFailure(UIBenchmarkManifestAggregator.validate(duplicatePID)))

        var duplicateScenario = manifests
        duplicateScenario[3] = scenarioManifest(
            identity: identity, scenario: .section69, pid: 104)
        #expect(isFailure(UIBenchmarkManifestAggregator.validate(duplicateScenario)))

        var mixedRevision = manifests
        mixedRevision[3] = scenarioManifest(
            identity: revisionIdentity(binary: String(repeating: "b", count: 64)),
            scenario: .ktvStage,
            pid: 104)
        #expect(isFailure(UIBenchmarkManifestAggregator.validate(mixedRevision)))

        var failed = manifests
        failed[3] = scenarioManifest(
            identity: identity, scenario: .ktvStage, pid: 104, passed: false)
        #expect(isFailure(UIBenchmarkManifestAggregator.validate(failed)))

        var numericallyFailed = manifests
        numericallyFailed[3] = scenarioManifest(
            identity: identity,
            scenario: .ktvStage,
            pid: 104,
            maximumDeliveryNanoseconds: 9_000_000)
        #expect(isFailure(UIBenchmarkManifestAggregator.validate(numericallyFailed)))

        let longest = zip(
            UIBenchmarkContract.requiredScenarios,
            [Int32(301), 302, 303, 304]
        ).map {
            scenarioManifest(
                identity: identity, scenario: $0.0, pid: $0.1, requestedSeconds: 60)
        }
        #expect(try UIBenchmarkManifestAggregator.validate(longest).get().scenarios.count == 4)
    }

    @Test("revision identity refuses an omitted or malformed binding")
    func revisionIdentityIsFailClosed() {
        var environment = revisionEnvironment()
        #expect(UIBenchmarkRevisionIdentity.resolve(environment: environment) != nil)
        environment.removeValue(forKey: "YUNAUDIO_UI_BENCHMARK_OS_BUILD")
        #expect(UIBenchmarkRevisionIdentity.resolve(environment: environment) == nil)
        environment = revisionEnvironment()
        environment["YUNAUDIO_UI_BENCHMARK_BINARY_SHA256"] = "not-a-sha"
        #expect(UIBenchmarkRevisionIdentity.resolve(environment: environment) == nil)
        environment = revisionEnvironment()
        environment["YUNAUDIO_UI_BENCHMARK_THRESHOLD_REVISION"] = "old-threshold"
        #expect(UIBenchmarkRevisionIdentity.resolve(environment: environment) == nil)
    }

    @Test("the fourth fresh process atomically produces one canonical aggregate")
    func manifestStoreAggregatesOnceComplete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "YunAudio-ui-manifest-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = revisionIdentity()
        let manifests = zip(
            UIBenchmarkContract.requiredScenarios,
            [Int32(201), 202, 203, 204]
        ).map { scenarioManifest(identity: identity, scenario: $0.0, pid: $0.1) }

        for manifest in manifests.dropLast() {
            #expect(try UIBenchmarkManifestStore.write(manifest, to: directory) == .recorded)
        }
        let outcome = try UIBenchmarkManifestStore.write(manifests[3], to: directory)
        guard case .aggregated(let aggregateURL) = outcome else {
            Issue.record("the fourth scenario did not aggregate")
            return
        }
        let data = try Data(contentsOf: aggregateURL)
        let aggregate = try JSONDecoder().decode(UIBenchmarkAggregateManifest.self, from: data)
        #expect(aggregate.scenarios.count == 4)
        #expect(Set(aggregate.scenarios.map(\.processIdentifier)).count == 4)
        #expect(data.count <= UIBenchmarkContract.maximumManifestBytes)
        #expect(throws: UIBenchmarkManifestValidationError.self) {
            try UIBenchmarkManifestStore.write(manifests[3], to: directory)
        }
    }

    @Test("drawing variants require both no-audio benchmark guards")
    func drawingVariantsAreGuarded() {
        let unguarded = YunUIBenchmarkConfiguration.resolve(environment: [
            "YUNAUDIO_UI_BENCHMARK_VARIANT": "scroll-fades-off"
        ])
        #expect(!unguarded.isEnabled)
        #expect(unguarded.effectiveVariant == .full)
        #expect(!unguarded.suppressesApplicationRefresh)

        let guarded = YunUIBenchmarkConfiguration.resolve(environment: [
            "YUNAUDIO_UI_BENCHMARK": "1",
            "YUNAUDIO_SCREENSHOT_NO_AUDIO": "1",
            "YUNAUDIO_UI_BENCHMARK_VARIANT": "scroll-fades-off",
        ])
        #expect(guarded.isEnabled)
        #expect(guarded.requestedVariant == .scrollFadesOff)
        #expect(guarded.effectiveVariant == .scrollFadesOff)
        #expect(guarded.suppressesApplicationRefresh)

        let legacy = YunUIBenchmarkConfiguration.resolve(environment: [
            "YUNAUDIO_UI_BENCHMARK": "1",
            "YUNAUDIO_SCREENSHOT_NO_AUDIO": "1",
            "YUNAUDIO_UI_BENCHMARK_VARIANT": "lyric-fill-legacy",
        ])
        #expect(legacy.requestedVariant == .lyricFillLegacy)

        let frozen = YunUIBenchmarkConfiguration.resolve(environment: [
            "YUNAUDIO_UI_BENCHMARK": "1",
            "YUNAUDIO_SCREENSHOT_NO_AUDIO": "1",
            "YUNAUDIO_UI_BENCHMARK_VARIANT": "lyric-fill-static",
        ])
        #expect(frozen.requestedVariant == .lyricFillStatic)

        let invalid = YunUIBenchmarkConfiguration.resolve(environment: [
            "YUNAUDIO_UI_BENCHMARK": "1",
            "YUNAUDIO_SCREENSHOT_NO_AUDIO": "1",
            "YUNAUDIO_UI_BENCHMARK_VARIANT": "everything-off",
        ])
        #expect(invalid.requestedVariant == nil)
        #expect(invalid.effectiveVariant == .full)
    }

    @Test("the launcher makes the benchmark a guarded no-audio verification run")
    func launcherCarriesEverySafetyGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcher = try String(
            contentsOf: repository.appendingPathComponent("App/benchmark-ui.sh"),
            encoding: .utf8)
        let app = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/YunAudioApp.swift"),
            encoding: .utf8)
        let benchmark = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/UIResourceBenchmark.swift"),
            encoding: .utf8)
        let manifest = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/UIBenchmarkManifest.swift"),
            encoding: .utf8)
        let model = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/RouterModel.swift"),
            encoding: .utf8)
        let transport = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/KTVTransportBar.swift"),
            encoding: .utf8)

        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK=1"))
        #expect(launcher.contains("YUNAUDIO_SCREENSHOT_NO_AUDIO=1"))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_VARIANT=\"$VARIANT_TO_MEASURE\""))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_SCENARIO=\"$scenario\""))
        #expect(launcher.contains("SCENARIOS=(app-open panel-closed section-69 ktv-stage)"))
        #expect(launcher.contains("kill -0 \"$benchmark_pid\""))
        #expect(launcher.contains("deadline_seconds="))
        #expect(launcher.contains("-newer \"$APP\""))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_GIT_HEAD=\"$GIT_HEAD\""))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_DIRTY_DIGEST=\"$DIRTY_DIGEST\""))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_SOURCE_SHA256=\"$SOURCE_TREE_SHA\""))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_BINARY_SHA256=\"$BINARY_SHA\""))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_TOOLCHAIN_SHA256=\"$TOOLCHAIN_SHA\""))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_OS_BUILD=\"$OS_BUILD\""))
        #expect(launcher.contains("aggregate.json"))
        #expect(launcher.contains("UI benchmark binary SHA-256"))
        #expect(launcher.contains("UI benchmark MainActor distribution"))
        #expect(app.contains("UIResourceBenchmark.run(model: model)"))
        #expect(
            app.contains("UIResourceBenchmark.beginColdLaunchProbe(environment: environment)"))
        let coldBegin = try #require(app.range(of: "UIResourceBenchmark.beginColdLaunchProbe"))
        let modelPolicy = try #require(app.range(of: "AppStartup.modelPolicy"))
        #expect(coldBegin.lowerBound < modelPolicy.lowerBound)
        #expect(
            model.contains(
                "if startupPolicy.refreshesDevicesDuringConstruction { refreshDevices() }"
            ))
        #expect(
            model.contains(
                "startsClientImmediately: startupPolicy.startsMIDIImmediatelyDuringConstruction"
            ))
        #expect(
            benchmark.contains(
                "model.prepareForRendering(refreshesApplications: false)"))
        #expect(benchmark.contains("guard fixtureIsIsolated(model) else"))
        let coldBranch = try #require(benchmark.range(of: "if scenario == .appOpen"))
        let renderFixture = try #require(benchmark.range(of: "model.prepareForRendering"))
        #expect(coldBranch.lowerBound < renderFixture.lowerBound)
        #expect(benchmark.contains("UI benchmark fresh process"))
        #expect(benchmark.contains("UI benchmark composition cards"))
        #expect(benchmark.contains("UI benchmark section-69 boundary"))
        #expect(benchmark.contains("section69LyricFixture"))
        #expect(benchmark.contains("!model.canCancelLeadVocal"))
        #expect(benchmark.contains("!KTVWindow.isVisible"))
        #expect(
            benchmark.contains(
                "[\"MainWindow\", \"SingingPanel\", \"KTVTransportPanel\", \"KTVStage\"]"))
        #expect(benchmark.contains("moving immediate"))
        #expect(benchmark.contains("MainRunLoopDelivery.perform"))
        #expect(benchmark.contains("cadenceNanoseconds"))
        #expect(benchmark.contains("producerMisses"))
        #expect(benchmark.contains("window.orderOut(nil)"))
        #expect(benchmark.contains("task scheduling lateness"))
        #expect(manifest.contains("expected exactly four scenario manifests"))
        #expect(manifest.contains("every scenario must run in a fresh process"))
        #expect(manifest.contains("scenario manifests belong to different revisions"))
        #expect(manifest.contains("maximumManifestBytes = 64 * 1024"))
        #expect(transport.contains("\"KTVTransportStage\" : \"KTVTransportPanel\""))
    }

    @Test("the fixture cannot enumerate or display the person's applications")
    func applicationFixtureIsIsolated() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appList = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/AppSourceList.swift"),
            encoding: .utf8)
        let mainWindow = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/MainWindow.swift"),
            encoding: .utf8)

        #expect(
            appList.contains(
                "!YunUIBenchmarkConfiguration.process.suppressesApplicationRefresh"))
        #expect(
            appList.contains(
                "RouterModel.AppListing(applications: [], overflow: 0, background: [])"))
        #expect(
            mainWindow.contains(
                "YunUIBenchmarkConfiguration.process.isEnabled ? [] : model.userPresets"))
        #expect(
            mainWindow.contains(
                "if !YunUIBenchmarkConfiguration.process.isEnabled,\n"
                    + "                            !model.capturedAppBundleIDs.isEmpty"))
    }

    @Test("each compositor mode changes one drawing family")
    func compositorModesHaveNarrowCallSites() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let theme = try String(
            contentsOf: repository.appendingPathComponent("Sources/YunDesign/Theme.swift"),
            encoding: .utf8)
        let components = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunDesign/Components.swift"),
            encoding: .utf8)
        let probe = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunDesign/UIBenchmarkProbe.swift"),
            encoding: .utf8)
        let compositor = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/CompositedLyricFill.swift"),
            encoding: .utf8)

        #expect(theme.ranges(of: ".cardEffectsOff").count == 1)
        #expect(theme.ranges(of: ".windowMaterialOff").count == 1)
        #expect(components.ranges(of: ".scrollFadesOff").count == 1)
        #expect(probe.ranges(of: "case lyricFillStatic").count == 1)
        #expect(probe.ranges(of: "case lyricFillLegacy").count == 1)
        // One branch removes the anchor dependency and the other freezes the
        // compositor value. Both are required for a genuinely static control.
        #expect(compositor.ranges(of: ".lyricFillStatic").count == 2)
        #expect(compositor.ranges(of: ".lyricFillLegacy").count == 1)
        #expect(compositor.contains("variant == .lyricFillStatic ? 0.5 : nil"))
        // The ten-hertz model value belongs to the legacy branch and to nothing
        // else — production animates on the compositor and never observes it.
        // Counted rather than merely found: the previous form named a `let` that
        // a refactor had already folded into the call, so the assertion had
        // stopped standing for anything.
        #expect(compositor.ranges(of: "model.lyricProgress").count == 1)
        #expect(
            compositor.contains(
                "swiftUISurface(progress: model.lyricProgress, animates: true)"))
    }

    private func evidence(
        _ basis: MainActorScenarioEvidence,
        delivered: Int,
        misses: Int,
        coverage: Double
    ) -> MainActorScenarioEvidence {
        let distribution = MainActorLatencyDistribution(
            nanoseconds: [UInt64](repeating: 200_000, count: delivered))
        return MainActorScenarioEvidence(
            passCount: basis.passCount,
            expectedSamples: basis.expectedSamples,
            deliveredSamples: delivered,
            producerMisses: misses,
            minimumSampleCoverage: coverage,
            producer: distribution,
            delivery: distribution)
    }

    private func revisionIdentity(
        binary: String = String(repeating: "a", count: 64)
    ) -> UIBenchmarkRevisionIdentity {
        UIBenchmarkRevisionIdentity(
            schemaVersion: UIBenchmarkContract.schemaVersion,
            runGroupID: "test-run-group",
            gitHEAD: String(repeating: "a", count: 40),
            dirtyDigest: String(repeating: "a", count: 64),
            sourceTreeSHA256: String(repeating: "a", count: 64),
            binarySHA256: binary,
            toolchainSHA256: String(repeating: "a", count: 64),
            operatingSystemBuild: "26A123",
            fixtureRevision: UIBenchmarkContract.fixtureRevision,
            thresholdRevision: UIBenchmarkContract.thresholdRevision)
    }

    private func revisionEnvironment() -> [String: String] {
        [
            "YUNAUDIO_UI_BENCHMARK_RUN_GROUP": "test-run-group",
            "YUNAUDIO_UI_BENCHMARK_GIT_HEAD": String(repeating: "a", count: 40),
            "YUNAUDIO_UI_BENCHMARK_DIRTY_DIGEST": String(repeating: "a", count: 64),
            "YUNAUDIO_UI_BENCHMARK_SOURCE_SHA256": String(repeating: "a", count: 64),
            "YUNAUDIO_UI_BENCHMARK_BINARY_SHA256": String(repeating: "a", count: 64),
            "YUNAUDIO_UI_BENCHMARK_TOOLCHAIN_SHA256": String(repeating: "a", count: 64),
            "YUNAUDIO_UI_BENCHMARK_OS_BUILD": "26A123",
            "YUNAUDIO_UI_BENCHMARK_FIXTURE_REVISION":
                UIBenchmarkContract.fixtureRevision,
            "YUNAUDIO_UI_BENCHMARK_THRESHOLD_REVISION":
                UIBenchmarkContract.thresholdRevision,
        ]
    }

    private func scenarioManifest(
        identity: UIBenchmarkRevisionIdentity,
        scenario: UIResourceBenchmarkScenario,
        pid: Int32,
        passed: Bool = true,
        requestedSeconds: Double = 4,
        maximumDeliveryNanoseconds: UInt64 = 200_000
    ) -> UIBenchmarkScenarioManifest {
        let passCount =
            scenario == .appOpen || scenario == .panelClosed
                || scenario == .windowMovement ? 1 : 5
        let plannedSeconds: Double
        switch scenario {
        case .appOpen, .panelClosed, .windowMovement:
            plannedSeconds = requestedSeconds
        case .section69:
            plannedSeconds = max(10, requestedSeconds) + requestedSeconds * 4
        case .ktvStage:
            plannedSeconds = 4 + requestedSeconds * 4
        case .standard:
            plannedSeconds = requestedSeconds
        }
        let sampleCount = Int(plannedSeconds * 1_000)
        let producer = MainActorLatencyDistribution(
            samples: sampleCount,
            p50Seconds: 0.0002,
            p99Seconds: 0.0002,
            maximumSeconds: 0.0002)
        let delivery = MainActorLatencyDistribution(
            samples: sampleCount,
            p50Seconds: 0.0002,
            p99Seconds: 0.0002,
            maximumSeconds: Double(maximumDeliveryNanoseconds) / 1e9)
        return UIBenchmarkScenarioManifest(
            identity: identity,
            scenario: scenario,
            processIdentifier: pid,
            style: "flat",
            variant: "full",
            requestedSeconds: requestedSeconds,
            mainActor: MainActorScenarioEvidence(
                passCount: passCount,
                expectedSamples: sampleCount,
                deliveredSamples: sampleCount,
                producerMisses: 0,
                minimumSampleCoverage: 1,
                producer: producer,
                delivery: delivery),
            resources: [
                UIBenchmarkResourcePhase(
                    name: scenario.rawValue,
                    processorSeconds: 0.01,
                    wallSeconds: 4,
                    footprintBytes: 1,
                    bodyEvaluations: [:])
            ],
            passed: passed)
    }

    private func isFailure<Success, Failure: Error>(
        _ result: Result<Success, Failure>
    ) -> Bool {
        if case .failure = result { return true }
        return false
    }
}
