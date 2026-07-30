import Foundation
import Testing
import YunDesign

@testable import YunAudioApp

@Suite("UI resource benchmark boundary")
struct UIResourceBenchmarkTests {
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
        let model = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/RouterModel.swift"),
            encoding: .utf8)

        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK=1"))
        #expect(launcher.contains("YUNAUDIO_SCREENSHOT_NO_AUDIO=1"))
        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK_VARIANT=\"$VARIANT_TO_MEASURE\""))
        #expect(app.contains("UIResourceBenchmark.run(model: model)"))
        #expect(
            model.contains(
                "if Self.isVerificationProcess, !Self.isUIBenchmarkProcess { refreshDevices() }"
            ))
        #expect(
            model.contains(
                "Self.isVerificationProcess && !Self.isUIBenchmarkProcess"))
        #expect(
            benchmark.contains(
                "model.prepareForRendering(refreshesApplications: false)"))
        #expect(benchmark.contains("guard fixtureIsIsolated(model) else { return false }"))
        #expect(benchmark.contains("UI benchmark fresh process"))
        #expect(benchmark.contains("UI benchmark composition cards"))
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

        #expect(theme.ranges(of: ".cardEffectsOff").count == 2)
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
}
