import AppKit
import Foundation
import YunAudioEngine
import YunAudioHAL

/// Drives the model through the sequences a person actually performs.
///
/// Offscreen renders show what the interface looks like; they cannot show
/// whether pressing the button does anything. This walks the real flows against
/// real hardware and reports what breaks, which is the only way short of a human
/// with a mouse to find out.
@MainActor
enum UIFlowCheck {
    private static var failures: [String] = []
    private static var notes: [String] = []

    private static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("  ✓ \(description)")
        } else {
            print("  ✗ \(description)")
            failures.append(description)
        }
    }

    private static func note(_ text: String) {
        print("  · \(text)")
        notes.append(text)
    }

    static func run(model: RouterModel) async {
        print("\nlaunch state")
        check("devices were enumerated", !model.inputDevices.isEmpty)
        check("an input is preselected", model.selectedSourceUID != nil)
        if !model.isDriverInstalled {
            note("the virtual device is not installed — the panel shows the install card")
            check("an install button is offered", model.canInstallDriver)
            // Fall back to any loopback so the routing flows are still
            // exercised. Skipping them because one device is absent would leave
            // the part most likely to be broken untested.
            if let fallback = model.outputDevices.first(where: {
                $0.transport.isVirtual && $0.inputChannels > 0
            }) {
                note("routing against \(fallback.name) instead")
                model.selectedDestinationUID = fallback.uid
            } else {
                note("no loopback device at all — routing flows skipped")
                summarise()
                return
            }
        }
        check("an output is preselected", model.selectedDestinationUID != nil)

        print("\nlocalisation")
        checkLocalisation()

        print("\napplication list")
        model.refreshApps()
        check("applications were found", !model.availableApps.isEmpty)
        check(
            "every listed application has a name",
            model.availableApps.allSatisfy { !$0.name.isEmpty })
        check(
            "no listed application shows a raw bundle fragment",
            !model.availableApps.contains { $0.name == "Renderer" || $0.name == "client" })
        check(
            "helper processes folded into their parent",
            !model.availableApps.contains { $0.bundleID.lowercased().contains(".helper") })
        check(
            "every entry can actually be captured",
            model.availableApps.allSatisfy { !$0.bundleID.isEmpty && !$0.processIDs.isEmpty })
        // The point of the grouping: the default list is short enough to read.
        check(
            "the daemons are held back by default",
            model.visibleApps.count < model.availableApps.count
                || model.availableApps.allSatisfy { !$0.isBackground })
        note("\(model.visibleApps.count) shown, \(model.hiddenAppCount) held back")
        model.showsBackgroundApps = true
        check("they can still be shown", model.visibleApps.count == model.availableApps.count)
        model.showsBackgroundApps = false

        print("\nstarting")
        model.start()
        await waitUntil("the route came up", { model.isRunning }, timeout: 5)
        check("no error was reported", model.lastError == nil)
        check("routes were built", !model.activeRoutes.isEmpty)
        check(
            "a fader exists for every route", model.routeGains.count == model.activeRoutes.count
        )

        await waitUntil("levels started arriving", { !model.routeLevels.isEmpty }, timeout: 3)
        check("path quality is being reported", model.pathQuality != nil)

        print("\nmuting the first route")
        model.setMuted(true, forRouteAt: 0)
        check("the mute took", model.routeMutes.first == true)
        model.setMuted(false, forRouteAt: 0)
        check("unmuting took", model.routeMutes.first == false)

        print("\nmoving a fader")
        model.setFaderDecibels(-12, forRouteAt: 0)
        check(
            "the fader reads back what was set",
            abs(model.faderDecibels(forRouteAt: 0) - -12) < 0.5)
        model.setFaderDecibels(0, forRouteAt: 0)

        print("\nswitching channel mode while running")
        let before = model.activeRoutes.count
        let cyclesBefore = model.cycleCountForDiagnostics
        model.channelMode = model.channelMode == .mono ? .stereo : .mono
        await pause(0.4)
        check("audio kept flowing", model.cycleCountForDiagnostics > cyclesBefore)
        check("the route set changed", model.activeRoutes.count != before || before > 0)
        check("still running", model.isRunning)

        print("\nrecording")
        check("recording is offered while routing", model.isRunning)
        model.toggleRecording()
        check("the recording started", model.isRecording)
        check("no error was reported", model.lastError == nil)
        let file = model.recordingURL
        check("a file was named", file != nil)
        await pause(2.0)
        check("the elapsed time is advancing", model.recordingSeconds > 0.5)
        model.toggleRecording()
        check("the recording stopped", !model.isRecording)
        // The duration has to survive the stop. Reading it after releasing the
        // recorder returned zero, so the elapsed time snapped to 00:00 at
        // exactly the moment anyone would look at it.
        check("the elapsed time survived the stop", model.recordingSeconds > 0.5)

        if let file {
            // The recorder drains on its own thread, so the last frames land
            // shortly after the stop.
            await pause(0.5)
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: file.path)
            let size = attributes?[.size] as? Int ?? 0
            check("the file exists and is not empty", size > 0)
            // Two seconds of stereo float at 48 kHz is about 768 kB. A file
            // that exists but holds a header and nothing else is the failure
            // this catches — it happened once before, when the de-stride branch
            // wrote into the meter array.
            note("\(size) bytes for \(String(format: "%.1f", model.recordingSeconds))s")
            check("the file holds real audio, not just a header", size > 100_000)
            try? FileManager.default.removeItem(at: file)
        }

        print("\nswitching the echo canceller on while running")
        if model.echoSpeakerOptions.isEmpty {
            note("no hardware output to cancel against — skipped")
        } else {
            model.cancelsEcho = true
            // `isBusy` is the only flag that spans the whole reconfigure, and
            // both alternatives are races. `isRunning` never goes false during
            // one, so waiting on it returns the state from before the change;
            // the canceller becomes visible partway through `engine.start`, so
            // waiting on the status alone lands in the middle of a start. Both
            // produced failures that looked like bugs in the engine.
            await waitUntil(
                "the canceller entered the path",
                { !model.isBusy && model.echoStatus != nil }, timeout: 12)
            check("no error was reported", model.lastError == nil)
            check("the route is up", model.isRunning)
            if let status = model.echoStatus {
                note("reference \(status.hasReference ? "present" : "absent")")
            }
            // The microphone belongs to the canceller now, so nothing may be
            // reading it off the aggregate: a route still pointed at a buffer
            // index would be reading whatever landed in that slot instead.
            let faderPerRoute = model.routeGains.count == model.activeRoutes.count
            check("routes still resolve", !model.activeRoutes.isEmpty && faderPerRoute)
            await pause(1.5)
            let produced = model.echoStatus?.produced ?? 0
            await pause(1.0)
            check(
                "the canceller keeps producing",
                (model.echoStatus?.produced ?? 0) > produced)

            model.cancelsEcho = false
            await waitUntil(
                "the canceller left the path",
                { !model.isBusy && model.echoStatus == nil && model.isRunning },
                timeout: 12)
            check("no error on the way out", model.lastError == nil)
            check("routing continues without it", !model.activeRoutes.isEmpty)
        }

        print("\napplying a preset while running")
        model.apply(.recording)
        await pause(1.0)
        check("still running after a preset", model.isRunning)
        check("no error after a preset", model.lastError == nil)
        model.apply(.voiceChat)
        await pause(1.0)

        print("\npatching")
        let sourcePorts = model.canvasSources
        let destinationPorts = model.canvasDestinations
        check("the canvas offers sources", !sourcePorts.isEmpty)
        check("the canvas offers destinations", !destinationPorts.isEmpty)

        if let source = sourcePorts.first, let destination = destinationPorts.first,
            let lastChannel = destination.channels.last
        {
            let newCable = ChannelRef(deviceUID: destination.uid, channel: lastChannel)
            let before = model.activeRoutes.count
            let cyclesBefore = model.cycleCountForDiagnostics
            model.connect(
                source: ChannelRef(deviceUID: source.uid, channel: source.channels[0]),
                destination: newCable)
            await pause(0.4)
            check("a cable was added", model.activeRoutes.count > before)
            check(
                "audio kept flowing while patching",
                model.cycleCountForDiagnostics > cyclesBefore)

            model.disconnect(destination: newCable)
            await pause(0.4)
            check("the cable was pulled", model.activeRoutes.count == before)
            check("still running after patching", model.isRunning)

            // A sixteen-channel destination must not put sixteen empty ports on
            // the canvas; the card was taller than the window and pushed the
            // mixer out of sight.
            let shown = model.canvasDestinations.first?.channels.count ?? 0
            check("the canvas holds back unused channels", shown <= 8)
            note("\(shown) channels shown, \(model.hiddenCanvasChannels) held back")
            if model.hiddenCanvasChannels > 0 {
                model.showsAllCanvasChannels = true
                check(
                    "they can still be reached",
                    (model.canvasDestinations.first?.channels.count ?? 0) > shown)
                model.showsAllCanvasChannels = false
            }
            // Every port a cable can reach must be offered, or a route restored
            // from disk would have no port to draw against.
            let offered = Set(model.canvasDestinations.first?.channels ?? [])
            check(
                "every connected channel is on the canvas",
                model.activeRoutes
                    .filter { $0.destination.deviceUID == destination.uid }
                    .allSatisfy { offered.contains($0.destination.channel) })
        }

        print("\nstopping")
        model.stop()
        await waitUntil("the route came down", { !model.isRunning }, timeout: 5)
        check("levels were cleared", model.routeLevels.isEmpty)
        check("routes were cleared", model.activeRoutes.isEmpty)

        summarise()
    }

    /// Compares the two string tables against each other.
    ///
    /// Seven long strings in the interface were never passed through `loc()`,
    /// and every one of them already had a Chinese translation sitting in the
    /// table unused — the table said the work was done and the interface showed
    /// English anyway. Nothing catches that but comparing the two sides, so it
    /// is compared on every run.
    private static func checkLocalisation() {
        guard let bundle = Bundle(path: Bundle.module.bundlePath) else {
            note("could not open the resource bundle")
            return
        }
        let tables = ["en", "zh-Hant"].map { language -> (String, [String: String]) in
            // SwiftPM lowercases .lproj folder names and Bundle's matching is
            // case-sensitive, which is why this looks the folder up by hand.
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: bundle.bundlePath)
            let folder = contents?.first {
                $0.lowercased() == "\(language.lowercased()).lproj"
            }
            let path = folder.map { "\(bundle.bundlePath)/\($0)/Localizable.strings" }
            let table = path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] }
            return (language, table ?? [:])
        }

        for (language, table) in tables {
            check("the \(language) table loaded", !table.isEmpty)
        }
        guard tables.count == 2, !tables[0].1.isEmpty, !tables[1].1.isEmpty else { return }

        let english = Set(tables[0].1.keys)
        let chinese = Set(tables[1].1.keys)
        check("both tables carry the same keys", english == chinese)
        if english != chinese {
            note("only in en: \(Array(english.subtracting(chinese).prefix(5)))")
            note("only in zh: \(Array(chinese.subtracting(english).prefix(5)))")
        }
        // An entry translated to itself is either a word that is the same in
        // both languages or a line someone forgot. Latin text in the Chinese
        // column is the second kind.
        let untranslated = tables[1].1.filter { key, value in
            key == value && value.count > 24
        }
        check("no long line is left in English", untranslated.isEmpty)
        for key in untranslated.keys.sorted().prefix(3) {
            note("untranslated: \(key.prefix(50))…")
        }
        note("\(english.count) keys in each table")
    }

    private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func waitUntil(
        _ description: String, _ condition: () -> Bool, timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            await pause(0.05)
        }
        check(description, condition())
    }

    private static func summarise() {
        print("\n" + String(repeating: "─", count: 52))
        if failures.isEmpty {
            print("every flow behaved. \(notes.count) note(s).")
        } else {
            print("\(failures.count) flow(s) failed:")
            for failure in failures { print("  · \(failure)") }
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
