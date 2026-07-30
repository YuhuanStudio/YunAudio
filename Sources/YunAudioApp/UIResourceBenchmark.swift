import AppKit
import Darwin
import Foundation
import YunDesign

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
                cardShadows = variant == .cardEffectsOff ? 0 : cards
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
        guard
            let window = NSApp.windows.first(where: {
                $0.title == "YunAudio"
            })
        else {
            report("UI benchmark refused: the main window does not exist")
            return false
        }

        let requestedStyle =
            ProcessInfo.processInfo.environment["YUNAUDIO_UI_BENCHMARK_STYLE"] ?? "current"
        switch requestedStyle {
        case "flat":
            YunTheme.shared.style = .flat
        case "glass":
            YunTheme.shared.style = .glass
        case "current":
            break
        default:
            report("UI benchmark refused: style must be current, flat, or glass")
            return false
        }
        report(
            "UI benchmark fresh process \(getpid()), style \(requestedStyle), "
                + "variant \(variant.rawValue)")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "YunAudio-ui-benchmark-\(getpid()).lrc")
        // Off by default, so every figure recorded before this still means
        // what it meant.
        let usesLongLines =
            ProcessInfo.processInfo.environment["YUNAUDIO_UI_BENCHMARK_LYRICS"] == "long"
        report("UI benchmark lyric lines \(usesLongLines ? "long, word-timed" : "short")")
        do {
            try (usesLongLines ? longLyricFixture : lyricFixture)
                .write(to: fixture, atomically: true, encoding: .utf8)
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
            ProcessInfo.processInfo.environment["YUNAUDIO_UI_BENCHMARK_STAGE"] == "1"
        if measuresTheStage {
            // Left in front deliberately. A window the window server has
            // covered gets no updates, so re-fronting the inspector would
            // measure a stage that is not drawing and report it as cheap.
            KTVWindow.open(model: model)
        }
        report("UI benchmark ktv stage \(measuresTheStage ? "open" : "closed")")
        await settle(for: 1)
        guard fixtureIsIsolated(model) else { return false }

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
        model.stopWords()
        await settle(for: 0.15)
        let seeded = usage()
        let staticSeconds = 4.0
        let staticBefore = usage()
        await settle(for: staticSeconds)
        let staticAfter = usage()

        let requested =
            ProcessInfo.processInfo.environment["YUNAUDIO_UI_BENCHMARK_SECONDS"]
            .flatMap(Double.init) ?? 4
        let movingSeconds = max(4, min(60, requested))
        model.runWords(from: 0)
        guard await verifyLyricControl(in: window, variant: variant, model: model) else {
            return false
        }
        model.runWords(from: 0)
        await settle(for: 0.15)
        BodyCount.reset()
        BodyCount.isCounting = true
        report("UI benchmark counted moving pass started")
        let countedBefore = usage()
        await advance(model, for: movingSeconds)
        let countedAfter = usage()
        BodyCount.isCounting = false

        var movingSamples: [Double] = []
        var movingAfter = countedAfter
        for sample in 1...3 {
            model.runWords(from: 0)
            await settle(for: 0.15)
            report("UI benchmark uncounted moving pass \(sample) started")
            let movingBefore = usage()
            await advance(model, for: movingSeconds)
            movingAfter = usage()
            movingSamples.append(movingAfter.processorSeconds - movingBefore.processorSeconds)
        }

        let staticCPU = staticAfter.processorSeconds - staticBefore.processorSeconds
        let countedCPU = countedAfter.processorSeconds - countedBefore.processorSeconds
        let sortedMoving = movingSamples.sorted()
        let movingCPU = sortedMoving[sortedMoving.count / 2]
        report(
            "UI benchmark uncounted samples "
                + movingSamples.map { String(format: "%.0f ms", $0 * 1_000) }
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
                    "UI benchmark counted moving %.0f ms, instrumentation delta %.0f ms",
                countedCPU * 1_000, (countedCPU - movingCPU) * 1_000))
        report(
            "UI benchmark footprint seeded \(mebibytes(seeded.footprintBytes)) MiB, "
                + "final \(mebibytes(movingAfter.footprintBytes)) MiB")
        for (name, count) in BodyCount.counts.sorted(by: { $0.value > $1.value }) {
            report(
                String(
                    format: "UI benchmark body %-16s %4d (%.2f Hz)",
                    (name as NSString).utf8String!, count,
                    Double(count) / movingSeconds))
        }
        return true
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

        let hasExpectedTree =
            model.isRunning
            && model.inputDevices.isEmpty
            && model.outputDevices.isEmpty
            && model.selectedSource == nil
            && model.selectedDestination == nil
            && model.buses.isEmpty
            && model.activeRoutes.isEmpty
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
                    + "buses \(model.buses.count), routes \(model.activeRoutes.count), "
                    + "tab \(model.inspectorTab), track \(model.nowPlaying != nil), "
                    + "lyrics \(model.lyrics != nil), "
                    + "pills \(StatusPills.pills(for: model).count))")
            return false
        }
        return true
    }

    private static func advance(_ model: RouterModel, for seconds: Double) async {
        let frames = Int(seconds * 20)
        let began = DispatchTime.now().uptimeNanoseconds
        for frame in 1...frames {
            model.refreshNowPlaying()
            let deadline = began + UInt64(frame) * 50_000_000
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                try? await Task.sleep(nanoseconds: deadline - now)
            }
        }
    }

    private static func settle(for seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
