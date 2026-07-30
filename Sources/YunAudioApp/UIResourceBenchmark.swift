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

    static func run(model: RouterModel) async -> Bool {
        guard ProcessInfo.processInfo.environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil else {
            report("UI benchmark refused: YUNAUDIO_SCREENSHOT_NO_AUDIO is required")
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
        report("UI benchmark style \(requestedStyle)")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "YunAudio-ui-benchmark-\(getpid()).lrc")
        do {
            try lyricFixture.write(to: fixture, atomically: true, encoding: .utf8)
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
        await settle(for: 1)

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
        BodyCount.reset()
        BodyCount.isCounting = true
        report("UI benchmark counted moving pass started")
        let countedBefore = usage()
        await advance(model, for: movingSeconds)
        let countedAfter = usage()
        BodyCount.isCounting = false

        model.runWords(from: 0)
        report("UI benchmark uncounted moving pass started")
        let movingBefore = usage()
        await advance(model, for: movingSeconds)
        let movingAfter = usage()

        let staticCPU = staticAfter.processorSeconds - staticBefore.processorSeconds
        let countedCPU = countedAfter.processorSeconds - countedBefore.processorSeconds
        let movingCPU = movingAfter.processorSeconds - movingBefore.processorSeconds
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
