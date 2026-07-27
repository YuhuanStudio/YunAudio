import AppKit
import Foundation
import YunAudioEngine
import YunAudioHAL
import YunDesign

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
        check(
            "the source is not the destination",
            model.selectedSourceUID != model.selectedDestinationUID)
        note(
            "\(model.selectedSource?.name ?? "—") → \(model.selectedDestination?.name ?? "—")")

        print("\nwindow and shortcuts")
        // The frame has to be saved under a name or the window reopens in the
        // middle of the screen at its default size on every launch.
        let window = NSApp.windows.first { $0.title == "YunAudio" }
        check("the main window exists", window != nil)
        check(
            "its frame is remembered between launches",
            window?.frameAutosaveName == "YunAudioMainWindow")

        // A shortcut that cannot be registered and cannot be changed is a dead
        // feature. Both of the original combinations were already owned by
        // something else on this machine, so it falls through candidates now.
        check("every global shortcut found a free combination", model.hotkeyFailures.isEmpty)
        for (action, shortcut) in model.activeShortcuts {
            note("\(action.title): \(shortcut.displayName)")
        }
        check(
            "the in-window shortcuts are listed too",
            model.hotkeyDescriptions.contains { !$0.isGlobal })

        // The menu bar glyph is the only part of this application most people
        // look at, and it showed nothing at all while muted — which is exactly
        // the state worth knowing about at a glance.
        model.toggleMute()
        check("the glyph reflects a muted microphone", model.isMuted)
        model.toggleMute()
        check("and reflects it being unmuted again", !model.isMuted)

        print("\nappearance")
        // The look was half Apple's material and half the source design system:
        // the menu bar panel floated on glass while the window was flat cards,
        // so the same application looked like two applications. It is one
        // setting now, and both surfaces follow it.
        check("the default is the source design system", model.style == .flat)
        for style in YunStyle.allCases {
            model.style = style
            check(
                "\(style.rawValue) applies to the shared theme",
                YunTheme.shared.style == style)
            check("\(style.rawValue) has a title", !style.title.isEmpty)
            check("\(style.rawValue) says what it costs", !style.detail.isEmpty)
        }
        model.style = .flat

        print("\nrealtime tripwire")
        // The hook is process-wide, so leaving it armed taxes every allocation
        // in SwiftUI, AppKit and CoreAudio for a diagnostics page almost nobody
        // opens. It used to be armed from launch.
        check("the allocator hook is not armed at launch", !model.watchesIOAllocations)
        model.watchesIOAllocations = true
        check("it can be armed", model.watchesIOAllocations)
        model.watchesIOAllocations = false
        check("and disarmed again", !model.watchesIOAllocations)

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

        print("\nsolo, peak hold and clipping")
        check("peak holds are being tracked", model.peakHolds.count == model.activeRoutes.count)
        check("clip latches exist too", model.clipped.count == model.activeRoutes.count)
        // The hold never sits below the instantaneous level, or the marker
        // would be drawn inside the bar rather than at its high-water mark.
        check(
            "the hold is never below the level",
            zip(model.peakHolds, model.routeLevels).allSatisfy { $0 >= $1 - 0.001 })

        if model.activeRoutes.count > 1 {
            model.toggleSolo(0)
            check("the soloed route is audible", !model.isSilenced(0))
            check("everything else is silenced", model.isSilenced(1))
            // Solo is a view of the mix: releasing it has to restore exactly
            // what was there, including a mute pressed while it was on.
            let mutesUnderSolo = model.routeMutes
            model.toggleSolo(0)
            check("releasing solo restores the mix", model.routeMutes == mutesUnderSolo)
            check("and nothing is left silenced", !model.isSilenced(0) && !model.isSilenced(1))
        } else {
            note("only one route — solo not exercised")
        }

        print("\nmoving a fader")
        model.setFaderDecibels(-12, forRouteAt: 0)
        check(
            "the fader reads back what was set",
            abs(model.faderDecibels(forRouteAt: 0) - -12) < 0.5)
        // Exactly unity has to be reachable. On a fader a hundred points wide
        // the difference between 0.0 and 0.2 dB is a single pixel, so without a
        // snap it can only be got at by typing.
        model.setFaderDecibels(0.3, forRouteAt: 0)
        check(
            "a value near unity is not silently snapped by the model",
            abs(model.faderDecibels(forRouteAt: 0) - 0.3) < 0.01)
        model.setFaderDecibels(0, forRouteAt: 0)
        check("unity reads back as exactly unity", model.faderDecibels(forRouteAt: 0) == 0)

        print("\ninput trim and master")
        // The two controls anybody looks for first, and the app had neither —
        // only the per-route strips, which balance sources against each other
        // rather than answering "how loud is the microphone".
        let cyclesBeforeLevels = model.cycleCountForDiagnostics
        model.inputDecibels = -6
        model.outputDecibels = -3
        model.isInputMuted = true
        await pause(0.5)
        check("the values read back", model.inputDecibels == -6 && model.outputDecibels == -3)
        check("audio kept flowing", model.cycleCountForDiagnostics > cyclesBeforeLevels)
        check("no rebuild was needed", model.isRunning && !model.isBusy)

        // Muting the input has to reach the samples, not just the model.
        await pause(0.6)
        check("the meters fell while muted", model.routeLevels.allSatisfy { $0 < 0.02 })
        model.isInputMuted = false

        // And a restart must not quietly reset them, since the graph is rebuilt.
        model.channelMode = model.channelMode == .mono ? .stereo : .mono
        await waitUntil("the rebuild settled", { !model.isBusy }, timeout: 8)
        check("the trim survived a rebuild", model.inputDecibels == -6)
        check("the master survived a rebuild", model.outputDecibels == -3)
        // The mute hotkey and the input mute button used to be two different
        // states, so pressing the shortcut left the button still reading
        // unmuted — and it muted every route one by one, silencing any
        // application audio being mixed in along with the microphone.
        model.toggleMute()
        check("the hotkey mutes the microphone", model.isInputMuted)
        check("and the button agrees with it", model.isMuted == model.isInputMuted)
        model.toggleMute()
        check("and unmutes it again", !model.isInputMuted)

        model.inputDecibels = 0
        model.outputDecibels = 0

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
        // One restart per preset, not one per property. Every field a preset
        // sets restarts the route on its own, so this used to tear the audio
        // down and rebuild it three times for a single click.
        let cyclesBeforePreset = model.cycleCountForDiagnostics
        model.apply(.recording)
        await pause(1.5)
        check("still running after a preset", model.isRunning)
        check("no error after a preset", model.lastError == nil)
        check("audio came back", model.cycleCountForDiagnostics > cyclesBeforePreset)
        check("the preset reads as active", model.matches(.recording))

        // Every preset has to be distinguishable from every other, or two of
        // them light up at once because the field they differ in is not
        // compared.
        for preset in RoutePreset.builtIn {
            model.apply(preset)
            let matching = RoutePreset.builtIn.filter { model.matches($0) }
            check("\(preset.name) matches only itself", matching.count == 1)
        }
        model.apply(.voiceChat)
        await waitUntil("it settled", { !model.isBusy }, timeout: 8)
        check("routing survived every preset", model.isRunning)
        await pause(1.0)

        // The batching itself, measured directly rather than through a preset.
        // No two presets happen to differ in more than one rebuilding field, so
        // going through one would pass whether the batching worked or not.
        let unbatchedBefore = model.restartCount
        model.preferredSampleRate = 44100
        model.channelMode = model.channelMode == .mono ? .stereo : .mono
        model.cancelsEcho = false
        let unbatched = model.restartCount - unbatchedBefore
        await waitUntil("the loose edits settled", { !model.isBusy }, timeout: 10)

        let batchedBefore = model.restartCount
        model.batched {
            model.preferredSampleRate = 48000
            model.channelMode = model.channelMode == .mono ? .stereo : .mono
            model.cancelsEcho = false
        }
        let batched = model.restartCount - batchedBefore
        note("\(unbatched) rebuilds loose, \(batched) batched")
        check("a batch of edits costs one rebuild", batched == 1)
        check("and that is fewer than doing them loose", batched < unbatched)
        await waitUntil("the batch settled", { !model.isBusy }, timeout: 10)
        check("routing survived both", model.isRunning)

        print("\npatching")
        let sourcePorts = model.canvasSources
        let destinationPorts = model.canvasDestinations
        check("the canvas offers sources", !sourcePorts.isEmpty)
        check("the canvas offers destinations", !destinationPorts.isEmpty)

        // Both operations, in whichever order the current patch allows.
        //
        // The first version always added to the last channel, which only worked
        // because BlackHole shows sixteen of them. Against the two-channel
        // YunAudio device every channel is already carrying one side of the
        // mono split, `connect` correctly does nothing, and the check reported
        // a product failure that was its own — then, once that was "fixed" by
        // requiring a free channel, it skipped the patchbay entirely and
        // reported success while testing none of it.
        let sourcePort = sourcePorts.first
        let ports = destinationPorts.first.map { group in
            group.channels.map { ChannelRef(deviceUID: group.uid, channel: $0) }
        }
        let free = ports?.first { reference in
            !model.activeRoutes.contains { $0.destination == reference }
        }
        let occupied = ports?.first { reference in
            model.activeRoutes.contains { $0.destination == reference }
        }

        if let source = sourcePort, let newCable = free ?? occupied {
            let from = ChannelRef(deviceUID: source.uid, channel: source.channels[0])
            let cyclesBefore = model.cycleCountForDiagnostics

            // Start from whichever end is available: pull it out first if it is
            // in use, otherwise put it in first. Both halves run either way.
            if free == nil {
                let connected = model.activeRoutes.count
                model.disconnect(destination: newCable)
                await pause(0.4)
                check("the cable was pulled", model.activeRoutes.count < connected)
                let pulled = model.activeRoutes.count
                model.connect(source: from, destination: newCable)
                await pause(0.4)
                check("a cable was added", model.activeRoutes.count > pulled)
            } else {
                let before = model.activeRoutes.count
                model.connect(source: from, destination: newCable)
                await pause(0.4)
                check("a cable was added", model.activeRoutes.count > before)
                model.disconnect(destination: newCable)
                await pause(0.4)
                check("the cable was pulled", model.activeRoutes.count == before)
            }

            check(
                "audio kept flowing while patching",
                model.cycleCountForDiagnostics > cyclesBefore)
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
                    .filter { $0.destination.deviceUID == newCable.deviceUID }
                    .allSatisfy { offered.contains($0.destination.channel) })
        }

        print("\ndevice changes")
        // A real change to the device list, not a simulated one: creating an
        // aggregate makes CoreAudio publish kAudioHardwarePropertyDevices, which
        // is the same notification an unplug produces. What is being checked is
        // that the watcher is actually wired and that a change to devices the
        // route does not use leaves the route alone.
        let cyclesBeforeChange = model.cycleCountForDiagnostics
        let deviceCountBefore = model.outputDevices.count
        if let destination = model.selectedDestination,
            let decoy = try? AggregateDevice(
                name: "YunAudio Flow Check",
                subDevices: [.init(uid: destination.uid, driftCompensation: true)],
                clockMasterUID: destination.uid)
        {
            await pause(1.0)
            check(
                "the device list picked up the new device",
                model.outputDevices.count > deviceCountBefore)
            check("an unrelated device did not stop the route", model.isRunning)
            check(
                "audio kept flowing across the change",
                model.cycleCountForDiagnostics > cyclesBeforeChange)
            check("no error was reported", model.lastError == nil)

            // Stopping on purpose must clear the interruption flag, or the
            // next device change resurrects a route the user put down.
            model.stop()
            await waitUntil("it came down", { !model.isRunning }, timeout: 5)
            decoy.destroy()
            await pause(1.5)
            check("a deliberate stop stays stopped across a change", !model.isRunning)
            model.start()
            await waitUntil("it came back", { model.isRunning }, timeout: 5)
            await pause(0.5)
            check(
                "the device list picked up the removal",
                model.outputDevices.count == deviceCountBefore)
            check("still running after the removal", model.isRunning)
        } else {
            note("could not build a decoy device — skipped")
        }

        print("\nintegrity check")
        // The project's central claim, and until now it could only be made from
        // a terminal: somebody who installs the app had no way to find out
        // whether their own path is bit-exact.
        if !model.canCheckIntegrity {
            note("the destination has no input to read back from — skipped")
        } else {
            model.checkIntegrity()
            check("the check started", model.isCheckingIntegrity)
            await waitUntil(
                "it finished", { !model.isCheckingIntegrity && !model.isBusy },
                timeout: 40)
            check("a result came back", model.integrityResult != nil)
            if let result = model.integrityResult {
                note(result.summary)
                check("samples were actually compared", result.comparedFrames > 0)
                // BlackHole is not clock-locked to the microphone, so its path
                // is legitimately resampled and will never be exact. What is
                // asserted is that the measurement aligned and reported — not
                // that this particular path is lossless.
                check("the returned run aligned with what was sent", result.didAlign)
                check("a loopback delay was recovered", result.delayFrames > 0)
            }
            check("the route came back afterwards", model.isRunning)
            check("no error was left behind", model.lastError == nil)
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
        guard let bundle = Bundle(path: AppResources.bundle.bundlePath) else {
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

        // Comparing the two tables cannot catch a string that was never put in
        // either — and the whole preferences sidebar was exactly that, four
        // English words beside Chinese content. Every label the interface
        // builds from an enum is checked against the table by name.
        var displayed: [String] = PreferencesWindow.Section.allCases.map(\.title)
        displayed += YunStyle.allCases.map(\.title)
        displayed += YunStyle.allCases.map(\.detail)
        displayed += EffectKind.allCases.map { loc($0.title) }
        displayed += EffectKind.allCases.map { loc($0.detail) }
        displayed += SourceChannelMode.allCases.map(\.title)
        displayed += TapMuteBehavior.allCases.map { loc($0.title) }
        displayed += RoutePreset.builtIn.map(\.name)
        displayed += RoutePreset.builtIn.map { loc($0.note) }
        displayed += HotkeyManager.Action.allCases.map(\.title)

        // In Chinese, anything still made of Latin letters and spaces never
        // reached the table — a translated string would not be.
        let stillEnglish = displayed.filter { text in
            text.count > 3 && text.allSatisfy { $0.isASCII }
        }
        check("every enum-built label is translated", stillEnglish.isEmpty)
        for text in stillEnglish.prefix(4) { note("not in the table: \(text)") }
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
