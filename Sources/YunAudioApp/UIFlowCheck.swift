import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import YunAudioControl
import YunAudioEngine
import YunAudioHAL
import YunAudioOBS
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

    /// Which sections to run in full, from `YUNAUDIO_FLOWCHECK_ONLY`.
    ///
    /// The whole check drives real CoreAudio: it starts and stops routes about
    /// fifty times, and each start is seconds of genuine device work. Five
    /// minutes is the honest cost of testing an audio path against real
    /// hardware, and it is the right cost before a commit — but it is the wrong
    /// cost after changing one view, which is how it was being used.
    ///
    /// Sections outside the filter still *execute*, because the later ones
    /// depend on the state the earlier ones leave behind — a route that is up,
    /// a preset applied. What they stop doing is waiting around: the fixed
    /// pauses collapse and the timeouts shorten, so the parts nobody is looking
    /// at cost what the devices cost and nothing more.
    private static let wanted: Set<String> = {
        let raw = ProcessInfo.processInfo.environment["YUNAUDIO_FLOWCHECK_ONLY"] ?? ""
        return Set(
            raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty })
    }()

    private static var currentSection = ""

    /// True when the section being run is one somebody asked for.
    private static var inWantedSection: Bool {
        wanted.isEmpty || wanted.contains { currentSection.contains($0) }
    }

    private static var sectionStarted = Date()
    private static var sectionTimes: [(String, TimeInterval)] = []

    /// Sections still to come that somebody asked for.
    ///
    /// The filter used to save nothing after the last wanted section: the run
    /// carried on through every remaining one, each of which starts and stops
    /// real routes, and a check aimed at one section still cost the full run.
    /// Measured on this machine — a targeted run of a section a third of the
    /// way down took 143 s of which about 140 was sections nobody had asked
    /// for, and the whole of that time the audio hardware of the machine is
    /// being seized and released. That is not merely slow; it is what makes
    /// every other application on the desktop stutter while a check runs.
    ///
    /// So a filtered run ends when the last wanted section has. It does *not*
    /// skip the ones before, and that is deliberate rather than lazy: the later
    /// sections depend on the state the earlier ones leave behind — a route
    /// that is up, a preset applied — and a section run against a machine in
    /// the wrong state fails for reasons that have nothing to do with the code.
    private static var wantedRemaining: Set<String> = wanted

    /// True once every asked-for section has been run, so there is nothing left
    /// worth paying for.
    private static var nothingLeftToRun: Bool {
        !wanted.isEmpty && wantedRemaining.isEmpty
    }

    private static func section(_ name: String) throws {
        // Timed, and the slowest half dozen printed at the end. The whole check
        // is minutes long and it was not obvious where the minutes went — the
        // answer turned out to be route restarts, which are seconds of real
        // device work each and are worth being able to count.
        if !currentSection.isEmpty {
            sectionTimes.append((currentSection, Date().timeIntervalSince(sectionStarted)))
        }
        sectionStarted = Date()
        currentSection = name.lowercased()
        // Asked before the section is crossed off, and the order matters: the
        // first version crossed off and then tested, so entering the last
        // wanted section emptied the set and threw immediately — the run ended
        // at the top of the one section anybody had asked for, having checked
        // nothing, and said "every flow behaved".
        let isWanted = inWantedSection
        wantedRemaining = wantedRemaining.filter { !currentSection.contains($0) }
        print("\n" + name + (isWanted ? "" : "  (skimmed)"))
        // So the throw happens on arriving at a section nobody wants, with
        // nothing left to come. This one gets to run.
        if !isWanted, nothingLeftToRun {
            note("nothing else was asked for — ending here rather than running the rest")
            throw NothingLeftToRun()
        }
    }

    /// Thrown by `section` to end a filtered run at a section boundary.
    ///
    /// A throw rather than a flag every section would have to remember to
    /// check: there are seventy-eight of them, they are written inline one
    /// after another, and a flag that one of them forgets is a run that quietly
    /// carries on doing the expensive thing. This cannot be forgotten — the
    /// compiler will not let a `section` call be written without it.
    private struct NothingLeftToRun: Error {}

    private static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        // A skimmed section is not being tested, so what it observes is not
        // evidence either way. Recording a failure there would be reporting the
        // consequences of not having waited.
        guard inWantedSection else { return }
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

    /// Held for the whole run, so two copies cannot drive the same hardware.
    ///
    /// This check takes exclusive control of a real microphone and a real
    /// output. Two of them at once do not produce two results — they produce
    /// two wrong ones, because each takes devices the other is using. That
    /// stayed theoretical until several agents started working on this project
    /// in parallel, at which point a full run reported sixty-four failures,
    /// every one of them a consequence of the very first line failing: "no
    /// other copy is holding the devices".
    ///
    /// A file lock rather than a refusal. Refusing would make parallel work
    /// impossible; waiting makes it merely serial, which is what sharing one
    /// microphone means.
    private static var lock: Int32 = -1

    private static func takeTheHardware() async {
        let path = "/tmp/yunaudio-flowcheck.lock"
        lock = open(path, O_CREAT | O_RDWR, 0o666)
        guard lock >= 0 else { return }
        if flock(lock, LOCK_EX | LOCK_NB) == 0 { return }

        // Bounded, and the bound is the point. Waiting made parallel work
        // merely serial, which is the right trade for one microphone — but
        // nothing capped the queue, and with several sessions each running an
        // A/B comparison the queue reached five. Five runs of two to four
        // minutes is twenty minutes during which the audio hardware of the
        // whole machine is seized and released, every application on the
        // desktop stutters, and the last process in the queue has been sitting
        // there with a window open for a quarter of an hour.
        //
        // So it gives up and says so. A run that did not happen is a fact
        // somebody can act on; a run that silently started fifteen minutes late
        // is a mystery about why the machine was unusable.
        let limit = TimeInterval(
            ProcessInfo.processInfo.environment["YUNAUDIO_FLOWCHECK_WAIT"]
                .flatMap(Double.init) ?? 300)
        print(
            "waiting up to \(Int(limit))s for another flow check to finish with the devices…")
        let deadline = Date().addingTimeInterval(limit)
        // Blocking `flock` would be simpler and would block the run loop, which
        // this process needs: the model hops through the main actor and would
        // never make progress.
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                print(
                    """

                    another flow check still holds the devices after \(Int(limit))s — \
                    giving up rather than joining the queue.
                    nothing was checked. run it again when the machine is quiet, or \
                    raise the wait with YUNAUDIO_FLOWCHECK_WAIT=<seconds>.
                    """)
                exit(2)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static func releaseTheHardware() {
        guard lock >= 0 else { return }
        flock(lock, LOCK_UN)
        close(lock)
        lock = -1
    }

    /// How long the process had been alive when the run loop first reached us.
    ///
    /// Captured here rather than computed later because "launch" is a moment
    /// that has already passed by the time anything else in this file runs, and
    /// the run loop being alive with a model and a menu bar item on it is the
    /// closest thing to "the window is usable" that can be observed from inside
    /// the process. Everything from `exec` onwards is in it: dyld, the
    /// frameworks, `RouterModel.init` and the first pass through the scene.
    private static let launchSeconds: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let started =
            Double(info.kp_proc.p_starttime.tv_sec)
            + Double(info.kp_proc.p_starttime.tv_usec) / 1e6
        return Date().timeIntervalSince1970 - started
    }()

    static func run(model: RouterModel) async {
        // Read on the first line so it is the launch that is measured and not
        // the wait for the lock below, which is somebody else's flow check.
        _ = launchSeconds
        await takeTheHardware()
        // A filtered run ends by throwing out of whichever section was the last
        // one anybody asked for, which lands here. The summary is printed
        // either way, because a run that stopped early still found whatever it
        // found and the caller still has to be told.
        do {
            try await runSections(model: model)
        } catch {
            summarise()
        }
    }

    private static func runSections(model: RouterModel) async throws {
        try section("launch state")
        // The single-instance guard is bypassed for this mode, so two copies
        // can be running at once — and when they are, they fight over the same
        // microphone and the same aggregate. The result is dozens of unrelated
        // failures with nothing to connect them: recording writes nothing, the
        // canceller cannot claim the device, routes stop resolving. It took a
        // while to work that out the first time, so it is stated here instead.
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.executableURL?.lastPathComponent == "YunAudioApp"
        }
        check("no other copy is holding the devices", others.isEmpty)
        if !others.isEmpty {
            note(
                "\(others.count) other copy(ies) running — everything below is "
                    + "competing with them for the hardware")
        }
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
        // Not merely a different UID: a wireless headset publishes its
        // microphone and its speakers as two devices with the same name, and
        // routing one into the other passes every UID comparison and then fails
        // deep inside the aggregate. Every failure in one whole run today was
        // this, and the first line said only "Razer Barracuda (BT) → Razer
        // Barracuda (BT)", which reads like a sensible default.
        if let source = model.selectedSourceUID, let destination = model.selectedDestinationUID
        {
            check(
                "the two ends are not one headset",
                !model.isSamePhysicalDevice(source, destination))
        }
        check(
            "the source is not the destination",
            model.selectedSourceUID != model.selectedDestinationUID)
        note(
            "\(model.selectedSource?.name ?? "—") → \(model.selectedDestination?.name ?? "—")")

        try section("window and shortcuts")
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
            check("\(action.rawValue) can be written down", !shortcut.displayName.isEmpty)
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

        try section("appearance")
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

        // The icon the application draws for itself. Every style has to build,
        // because the picker draws all of them at once — one that returned a
        // blank image would show as an empty tile beside the others and the
        // preference would still save perfectly.
        let originalIcon = model.iconStyle
        // Before anything is changed. The model restores the chosen style while
        // there is no `NSApp` to put it on, and `NSApp?.` makes that a silent
        // no-op — so a saved choice could reach the picker and never reach the
        // icon, which looks identical to a choice that was never saved.
        check(
            "the saved icon style reached the application at launch",
            NSApp.applicationIconImage != nil)
        for style in YunIconBadge.styles {
            model.iconStyle = style.name
            check("\(style.name) is remembered", model.iconStyle == style.name)
            check(
                "\(style.name) draws something",
                YunIconBadge.bitmap(size: 64, style: style) != nil)
            check(
                "\(style.name) reaches the application's own icon",
                NSApp.applicationIconImage != nil)
        }
        // A name that is not in the list must land on one that is, or a
        // preferences file from a build that had a style this one dropped
        // restores an icon that cannot be drawn.
        model.iconStyle = "no-such-style"
        check(
            "an unknown style falls back rather than sticking",
            YunIconBadge.style(named: model.iconStyle).name == YunIconBadge.fallbackStyle)
        model.iconStyle = originalIcon

        try section("realtime tripwire")
        // The hook is process-wide, so leaving it armed taxes every allocation
        // in SwiftUI, AppKit and CoreAudio for a diagnostics page almost nobody
        // opens. It used to be armed from launch.
        check("the allocator hook is not armed at launch", !model.watchesIOAllocations)
        model.watchesIOAllocations = true
        check("it can be armed", model.watchesIOAllocations)
        model.watchesIOAllocations = false
        check("and disarmed again", !model.watchesIOAllocations)

        try section("saved presets")
        // A snapshot of everything, not a chosen subset. Somebody saving one
        // has just spent time getting a setup right, and one that quietly left
        // out the thing they were adjusting is worse than none.
        let presetsBefore = model.userPresets.count
        model.inputDecibels = -7
        model.voicePreset = .child
        model.saveCurrentAsPreset(named: "Flow check")
        check("it was saved", model.userPresets.count == presetsBefore + 1)
        check("and became the active one", model.activePresetName == "Flow check")

        // Change everything it captured, then bring it back.
        model.inputDecibels = 0
        model.voicePreset = .none
        if let saved = model.userPresets.first(where: { $0.name == "Flow check" }) {
            model.apply(saved)
            await waitUntil("applying it settled", { !model.isBusy }, timeout: 12)
            check("the level came back", model.inputDecibels == -7)
            check("the voice came back", model.voicePreset == .child)
            check("no error was reported", model.lastError == nil)
        } else {
            check("the saved preset can be found again", false)
        }

        // Saving over a name replaces rather than making a second one: a list
        // of "Podcast", "Podcast 2", "Podcast 3" with no way to tell which is
        // current is worse than refusing.
        model.saveCurrentAsPreset(named: "Flow check")
        check(
            "saving the same name replaces it",
            model.userPresets.filter { $0.name == "Flow check" }.count == 1)
        // A blank name is not a preset.
        model.saveCurrentAsPreset(named: "   ")
        check(
            "a blank name is refused",
            model.userPresets.count == presetsBefore + 1)

        if let saved = model.userPresets.first(where: { $0.name == "Flow check" }) {
            model.deletePreset(saved)
        }
        check("it can be deleted", model.userPresets.count == presetsBefore)
        // The built-in four are not somebody's to delete.
        if let builtIn = RoutePreset.builtIn.first {
            model.deletePreset(builtIn)
            check("a built-in preset is not deleted", RoutePreset.builtIn.count == 4)
        }
        model.voicePreset = .none
        model.inputDecibels = 0

        try section("voice presets")
        // The claim is that both halves move together. Pitch alone is a
        // chipmunk and formants alone is somebody talking through a tube; the
        // measurement that they really do is in the unit tests, and what is
        // checked here is that choosing one reaches the engine.
        for preset in VoicePreset.allCases {
            model.voicePreset = preset
            check("\(preset.rawValue) applied", model.voicePreset == preset)
            check(
                "\(preset.rawValue) enables only what it moves",
                preset.stages.allSatisfy { model.enabledEffects.contains($0) })
        }
        model.voicePreset = .masculineToFeminine
        note(
            String(
                format: "higher voice: %+.0f cents, %+.0f%% formants, %.0f ms",
                model.voicePreset.cents, model.voicePreset.formantPercent,
                model.voiceLatencyMilliseconds))
        check(
            "it costs something and says so", model.voiceLatencyMilliseconds > 0)
        model.voicePreset = .none
        check(
            "switching it off takes both stages back out",
            !model.enabledEffects.contains(.pitch)
                && !model.enabledEffects.contains(.formant))

        try section("third-party units")
        note("\(model.availablePlugins.count) Audio Unit effect(s) installed")
        // Apple's own are the built-in stages; listing them again would put
        // AUPeakLimiter in the picker beside the limiter in the panel above it.
        check(
            "none of Apple's own units are offered as plugins",
            model.availablePlugins.allSatisfy {
                $0.manufacturer != kAudioUnitManufacturer_Apple
            })
        check(
            "every offered plugin has a name",
            model.availablePlugins.allSatisfy { !$0.name.isEmpty })
        if let plugin = model.availablePlugins.first(where: \.loadsInProcess) {
            note("hosting \(plugin.manufacturerName) — \(plugin.name)")
            model.addPlugin(plugin)
            check("it is in the chain", model.enabledPlugins.contains(plugin))
            check(
                "adding it twice does nothing",
                {
                    model.addPlugin(plugin); return model.enabledPlugins.count == 1
                }())
            model.removePlugin(plugin)
            check("and it comes back out", model.enabledPlugins.isEmpty)
        } else {
            note("nothing installed that can load in-process — hosting not exercised")
        }

        try section("light ring")
        if model.lighting.isAvailable {
            for mode in LightingMode.allCases {
                model.lightingMode = mode
                await pause(0.4)
                check("\(mode.rawValue) applied", model.lightingMode == mode)
                check("no error from \(mode.rawValue)", model.lighting.lastError == nil)
            }
            // What only the device can answer: that frames actually reach
            // it and it holds what was sent. What the ring *shows* is checked
            // in the unit tests, where the router's own metering cannot
            // overwrite the level mid-assertion.
            model.lightingMode = .spectrum
            await pause(0.5)
            // Sampled several times rather than twice. Reading the device
            // competes with the render thread for it, so a single pair can come
            // back identical without the ring having stopped.
            var samples: [[UInt8]] = []
            for _ in 0..<6 {
                if let frame = model.lighting.currentFrame() { samples.append(frame) }
                await pause(0.25)
            }
            check("the device holds the frames it is sent", !samples.isEmpty)
            check("and they keep arriving", Set(samples).count > 1)
            note("\(Set(samples).count) distinct frames in \(samples.count) reads")

            // Left dark: hardware state outlives the process, and a ring stuck
            // on a colour after quitting looks like a fault.
            model.lightingMode = .off
            check("it ends dark", model.lightingMode == .off)
        } else {
            note("no device with a light ring attached")
        }

        try section("what each device actually publishes")
        // A device is not one object: it owns controls, one per channel per
        // scope, and which of them exist is a property of the driver rather
        // than of the hardware. The Seiren V3 Pro carries 0 to +36 dB of gain
        // in its own firmware and macOS publishes no volume control for it at
        // all, while the V2 X publishes one — nothing about the two devices
        // predicts that, and the only way to know is to ask.
        //
        // Printed rather than asserted, because it is an inventory of somebody
        // else's driver. What it is for is finding the control nobody thought
        // to look for.
        for device in (model.inputDevices + model.outputDevices).prefix(8) {
            let controls = device.controls()
            guard !controls.isEmpty else {
                note("\(device.name): publishes no controls at all")
                continue
            }
            // Every level control spelled out for the two devices this
            // project knows intimately, because "nine volume controls" is
            // where the interesting question starts rather than ends.
            if device.name.contains("Seiren") {
                for control in controls where control.className == "vlme" {
                    note(
                        "  \(device.name) vlme scope \(control.scopeName) "
                            + "element \(control.element) "
                            + (control.decibels.map { String(format: "%.1f dB", $0) }
                                ?? control.scalar.map { String(format: "%.2f", $0) } ?? "—")
                            + (control.isSettable ? " settable" : " read-only"))
                }
            }
            let summary = Dictionary(grouping: controls, by: \.className)
                .sorted { $0.key < $1.key }
                .map { name, list -> String in
                    let settable = list.filter(\.isSettable).count
                    return "\(name)×\(list.count)"
                        + (settable > 0 ? " (\(settable) settable)" : "")
                }
                .joined(separator: " ")
            note("\(device.name): \(summary)")
        }

        try section("the device's own monitoring")
        // "Zero-latency monitoring" on a microphone's box is not a figure of
        // speech: the signal never reaches the computer. This application's own
        // monitoring is 2.7 ms, which is good and is not zero. CoreAudio
        // publishes the level under the play-through scope and nothing on macOS
        // offers to move it.
        for device in model.inputDevices.prefix(6) {
            guard let level = device.playThrough() else { continue }
            note(
                "\(device.name): play-through element \(level.element), "
                    + (level.decibels.map { String(format: "%.1f dB", $0) } ?? "no mapping")
                    + (level.isSettable ? ", settable" : ", read-only"))
        }
        if model.hasHardwareMonitoring {
            let before = model.hardwareMonitorScalar
            model.hardwareMonitorScalar = 0.5
            await pause(0.3)
            check(
                "the device took the monitoring level",
                abs(model.hardwareMonitorScalar - 0.5) < 0.1)
            check("and it reads back as something", model.hardwareMonitorLabel != "—")
            model.hardwareMonitorScalar = before
            await pause(0.3)
            check("and it went back", abs(model.hardwareMonitorScalar - before) < 0.1)
        } else {
            note("this microphone does not monitor itself")
        }

        try section("hardware gain")
        // Which element it lives on, because the answer is what this project
        // got wrong for months: only the master was asked for, the Seiren V3
        // Pro publishes nothing there, and the written-up reverse engineering
        // agreed that macOS could not reach its gain. It publishes three, on
        // elements 1 to 3, each carrying the full range its firmware documents.
        for device in model.inputDevices.prefix(6) {
            guard let gain = device.hardwareGain(scope: kAudioObjectPropertyScopeInput)
            else { continue }
            note(
                "\(device.name): element \(gain.element), "
                    + (gain.decibelRange.map {
                        String(format: "%.0f…%.0f dB", $0.lowerBound, $0.upperBound)
                    }
                        ?? "no decibel mapping")
                    + (gain.isSettable ? ", settable" : ", read-only"))
        }
        // The microphone's own gain sits before the converter, so raising it
        // costs no headroom, while the trim afterwards can only amplify what
        // the converter already decided. They are different controls and the
        // interface had only the second one.
        if let gain = model.hardwareGain, gain.isSettable {
            note(
                "range "
                    + (gain.decibelRange.map {
                        String(format: "%.0f…%.0f dB", $0.lowerBound, $0.upperBound)
                    }
                        ?? "scalar only"))
            let original = model.hardwareGainScalar
            model.hardwareGainScalar = 0.4
            await pause(0.3)
            check(
                "the device took the new gain",
                abs(
                    (model.selectedSource?.hardwareGain(
                        scope: kAudioObjectPropertyScopeInput)?.scalar ?? -1) - 0.4) < 0.05)
            check("the readout is not empty", !model.hardwareGainLabel.isEmpty)
            model.hardwareGainScalar = original
        } else {
            note("this input publishes no settable gain of its own")
        }

        try section("driver freshness")
        // An older installed driver is missing whatever the newer one added,
        // silently, and every symptom looks like a bug in the application. It
        // cost an hour: the virtual device published no volume control, the
        // driver source implemented it perfectly, and the installed copy simply
        // predated the commit.
        if model.isDriverInstalled {
            note(
                model.driverIsOutOfDate
                    ? "the installed driver is NOT the one this app ships"
                    : "the installed driver matches this app")
            check(
                "the app can tell whether the driver is current",
                DriverInstaller.bundledDriverURL != nil)
        } else {
            note("no driver installed")
        }

        try section("our own device's controls")
        // Volume on an aggregate or virtual device is a well-known gap —
        // `proxy-audio-device` has a thousand stars for a driver that does only
        // this, and BlackHole's top-voted discussion is the same request. We
        // ship a virtual device, so the question is whether ours answers.
        if let ours = model.outputDevices.first(where: {
            $0.name.localizedCaseInsensitiveContains("YunAudio")
        }) {
            let volume = ours.hardwareGain(scope: kAudioObjectPropertyScopeOutput)
            // Only meaningful against the driver this app ships. An older one
            // will not have it, and saying so beats failing.
            if model.driverIsOutOfDate {
                note("skipped — the installed driver predates the volume controls")
            } else {
                check("our device publishes a volume control", volume != nil)
                check("and it is settable", volume?.isSettable == true)
            }
            if let volume {
                note(
                    String(
                        format: "output volume %.2f%@", volume.scalar,
                        volume.decibelRange.map {
                            String(format: " (%.0f…%.0f dB)", $0.lowerBound, $0.upperBound)
                        } ?? ""))
            }
        } else {
            note("our virtual device is not installed — its controls not exercised")
        }

        try section("device profiles")
        // Loaded from documents beside the application rather than compiled in,
        // which is the only reason supporting somebody else's microphone is a
        // text file rather than a release. It is also the sort of thing that
        // works in the build tree and ships broken, so the check is that they
        // are really there.
        note("\(DeviceChannelNames.shared.library.profiles.count) profile(s) loaded")
        check(
            "the shipped device profiles were found",
            !DeviceChannelNames.shared.library.profiles.isEmpty)
        check(
            "none of them failed to parse", DeviceChannelNames.shared.problems.isEmpty)
        for problem in DeviceChannelNames.shared.problems.prefix(3) { note(problem) }

        try section("channel naming")
        // CoreAudio says a device has three input channels and nothing about
        // what is on them. On the Seiren all three carry audio — processed, dry,
        // and past the microphone's own expander — so a number is not just
        // unhelpful, it is misleading.
        if let names = model.sourceChannelNames {
            note("named channels: \(names.map(\.name).joined(separator: ", "))")
            check(
                "every named channel says what it is", names.allSatisfy { !$0.detail.isEmpty })
            check("exactly one is the default", names.filter(\.isDefault).count == 1)
            // Against the translated name, not the raw one. The label goes
            // through loc() like every other string, so asserting the English
            // here would fail on a Chinese system for the right reason and
            // look like a bug.
            check(
                "the label comes from the name rather than the index",
                model.sourceChannelLabel(0) == loc(names[0].name))
        } else {
            note("this input has no known topology — labels fall back to numbers")
            check(
                "the fallback label is still a channel number",
                model.sourceChannelLabel(0).contains("1"))
        }

        try section("localisation")
        try checkLocalisation()

        try section("application list")
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

        try section("starting")
        model.start()
        // Fifteen seconds, not five. A device that cannot be started does not
        // always say so quickly: a display's audio endpoint takes about twelve
        // to come back with `AudioDeviceStart failed with 'stop'`, and a
        // shorter wait reports "did not come up" with no error attached, which
        // is the least useful thing it could say.
        await waitUntil("the route came up", { model.isRunning }, timeout: 15)
        // Said out loud rather than left to be inferred: when the route does not
        // come up, every check after it fails too, and the forty lines of
        // consequences are much louder than the one line of cause.
        if let error = model.lastError { note("the route said: \(error)") }

        // One unusable device must not turn into forty failures. If the saved
        // destination cannot be started — a display asleep, a headset that
        // wandered off — the rest of the flow is still worth running, so it
        // moves to the system's own output and says that it did.
        if !model.isRunning, let fallback = (try? AudioDevices.defaultOutput())??.uid,
            fallback != model.selectedDestinationUID
        {
            note("that destination will not start; moving to the system output")
            // Waited for: a failed start holds `isBusy` until the engine queue
            // unwinds, and `start()` returns immediately while it is set — so
            // calling it straight away does nothing at all and the retry looks
            // like a second failure.
            await waitUntil(
                "the failed start finished unwinding", { !model.isBusy }, timeout: 20)
            model.selectedDestinationUID = fallback
            model.start()
            await waitUntil("it came up on the system output", { model.isRunning }, timeout: 15)
        }
        check("no error was reported", model.lastError == nil)
        check("routes were built", !model.activeRoutes.isEmpty)
        check(
            "a fader exists for every route", model.routeGains.count == model.activeRoutes.count
        )

        await waitUntil("levels started arriving", { !model.routeLevels.isEmpty }, timeout: 3)
        check("path quality is being reported", model.pathQuality != nil)
        // The application routed audio into a virtual device and never said the
        // one thing it exists to enable: that the conferencing application has
        // to be pointed at that device. Stated as the rule rather than as
        // "there is a sentence", because which output happens to be preselected
        // is a property of the machine: routing into a real output is
        // monitoring and needs no further step, and a check that only ever saw
        // one of the two branches failed on any machine that picked the other.
        let routesToVirtual = model.selectedDestination?.transport.isVirtual ?? false
        check(
            "the next step is offered exactly when there is one",
            routesToVirtual == (model.nextStep != nil))
        if let next = model.nextStep {
            note(next)
        } else {
            note("destination is a real output — monitoring, so no next step")
        }

        try checkStatusPills(model: model)

        try section("muting the first route")
        model.setMuted(true, forRouteAt: 0)
        check("the mute took", model.routeMutes.first == true)
        model.setMuted(false, forRouteAt: 0)
        check("unmuting took", model.routeMutes.first == false)

        try section("solo, peak hold and clipping")
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

        try section("moving a fader")
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

        try section("input trim and master")
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

        // Muting the input has to reach the meters, not just the samples.
        //
        // A fixed pause and a threshold was the wrong assertion: the meter
        // falls at 20 dB a second, so how long it takes depends on how loud the
        // room was, and the check passed or failed with the traffic outside.
        // What is actually being claimed is that the meters read zero while
        // muted, so that is what is waited for.
        await waitUntil(
            "the meters fell while muted",
            { (0..<model.activeRoutes.count).allSatisfy { model.isSilenced($0) } },
            timeout: 3)
        check(
            "every route reads as silenced",
            (0..<model.activeRoutes.count).allSatisfy { model.isSilenced($0) })
        model.isInputMuted = false
        check(
            "and stops reading silenced when unmuted",
            !(0..<model.activeRoutes.count).allSatisfy { model.isSilenced($0) })

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

        try section("loudness and spectrum")
        // The unit tests prove the arithmetic against the standard. What they
        // cannot prove is that the ring is wired to the output bus at all — a
        // meter reading a ring nothing writes to reports a clean −inf, which is
        // indistinguishable from a quiet room until somebody speaks into it.
        model.isAnalysisVisible = true
        model.resetLoudness()
        await pause(upTo: 1.5, until: { model.analysis.duration > 0.5 })
        check("the analyser is receiving audio", model.analysis.duration > 0.5)
        note(
            String(
                format: "%.2fs measured, short-term %.1f LUFS, peak %.1f dBFS",
                model.analysis.duration, model.analysis.shortTerm, model.analysis.peak))
        check(
            "the spectrum has one band per position",
            model.analysis.bands.count == SpectrumAnalyser.bandCount)
        check(
            "every band is inside the display range",
            model.analysis.bands.allSatisfy { $0 >= 0 && $0 <= 1 })

        // Measured time has to track wall-clock time. If it lags, the ring is
        // dropping — which would silently bias the integrated figure towards
        // whatever the interface happened to catch.
        let measuredBefore = model.analysis.duration
        await pause(2.0)
        let advanced = model.analysis.duration - measuredBefore
        note(String(format: "%.2fs measured over 2.0s of wall clock", advanced))
        check("the analyser is not dropping audio", advanced > 1.8)

        // The master is applied before the fold, so turning it down has to move
        // the reading. This is what catches the tap being taken from the wrong
        // side of the gain stage.
        //
        // Only when there is a signal to move. A finite reading is not enough:
        // a room at −60 LUFS is the meter's own floor, and cutting 20 dB off
        // silence moves it by whatever the floor happens to be that second.
        // This check failed once for exactly that reason and passed on the next
        // run, which is worse than not running at all — a check that is
        // sometimes right teaches people to re-run rather than to look.
        if model.analysis.shortTerm.isFinite, model.analysis.shortTerm > -45 {
            let beforeCut = model.analysis.shortTerm
            model.outputDecibels = -20
            // Until the cut has actually shown up in the short-term reading.
            // The check below is the one that decides whether it is enough of a
            // cut; this only stops waiting once there is something to check.
            await pause(upTo: 3.5, until: { model.analysis.shortTerm < beforeCut - 10 })
            note(
                String(
                    format: "short-term %.1f → %.1f LUFS after a 20 dB cut",
                    beforeCut, model.analysis.shortTerm))
            check(
                "the master reaches the loudness meter",
                model.analysis.shortTerm < beforeCut - 10)
            model.outputDecibels = 0
        } else {
            note(
                String(
                    format: "the room is at %.1f LUFS — too quiet to measure a cut against",
                    model.analysis.shortTerm))
        }

        model.resetLoudness()
        check("reset clears the reading", model.analysis.duration == 0)

        try section("what the on-device model hears")
        model.isAnalysisVisible = true
        await pause(upTo: 2.0, until: { !model.analysis.verdictLabel.isEmpty })
        // The classifier is what makes the levelling trustworthy, so the check
        // is that it is actually producing a verdict — not what the verdict is.
        // A quiet room says "quiet", and that is a correct answer.
        note("heard \(model.heardVerdict.rawValue) (\(model.analysis.verdictLabel))")
        check(
            "the model produced a verdict",
            SoundClassifier.Verdict.allCases.contains(model.heardVerdict))
        check(
            "confidence is a probability",
            model.heardConfidence >= 0 && model.heardConfidence <= 1)

        try section("what is actually leaving")
        // The measurement that did not exist: every meter in the graph is taken
        // before gain, so nothing could see the trim or the master pushing the
        // signal past full scale. The far end heard distortion and this side
        // read healthy.
        note(
            String(
                format: "output peak %.1f dBFS, %@ clipped samples",
                model.outputPeakDecibels, "\(model.outputClippedSamples)"))
        check("the output level is being measured", model.outputPeak >= 0)
        check("a quiet room is not reported as clipping", model.outputClippedSamples == 0)
        // Deliberately pushed into clipping and back, because an indicator that
        // has never been seen to light is not an indicator.
        //
        // Both stages pushed rather than just the trim: a quiet room sat at
        // −50 dBFS, so +40 dB of trim still landed ten decibels short of full
        // scale and the check failed for want of signal rather than for want of
        // detection.
        //
        // And pushed until it clips rather than by a fixed amount, because a
        // fixed amount is a claim about how loud the room is, and this room
        // does not hold still. Measured on this machine, same binary, sixteen
        // runs of this section: with the old fixed +80 dB across the two
        // stages it failed **eight times out of eight**, landing between 34 and
        // 60 dB short of full scale; escalating passed eight out of eight, and
        // what it needed ranged from +40 dB to +120 dB across the pair. The
        // level the meter reports is no help in deciding in advance either — it
        // decays at 20 dB a second, so it describes what recently arrived
        // rather than what is arriving now, and it read *higher* on the run
        // that failed than on the run that passed.
        //
        // Escalating costs whoever is listening nothing: full scale is full
        // scale, so a louder push does not make a louder noise, and the loop
        // stops the moment anything reaches it.
        //
        // The first rung is deliberately below what any room needs, so the
        // escalation is exercised on every run and the note underneath reports
        // how much headroom the room actually had. A ladder whose first rung
        // always succeeds is a ladder nobody has ever climbed.
        let trimBeforeClip = model.inputDecibels
        let masterBeforeClip = model.outputDecibels
        var pushed: Float = 0
        for stage: Float in [20, 60, 100, 140] {
            pushed = stage
            model.inputDecibels = stage
            model.outputDecibels = stage
            await pause(upTo: 1.0, until: { model.outputClippedSamples > 0 })
            if model.outputClippedSamples > 0 { break }
        }
        note(
            String(
                format: "+%.0f dB on each stage: peak %.1f dBFS, %@ clipped",
                pushed, model.outputPeakDecibels, "\(model.outputClippedSamples)"))
        check("clipping is detected once it happens", model.outputClippedSamples > 0)
        check("and it is called clipping", model.outputVerdict == .clipping)
        model.inputDecibels = trimBeforeClip
        model.outputDecibels = masterBeforeClip
        model.clearClipping()
        await pause(0.3)
        check("the latch can be cleared", model.outputClippedSamples == 0)

        try section("balancing sources")
        // The whole flow, at speed. What it cannot check on its own is whether
        // anybody spoke — a silent room produces a failure, and that failure is
        // itself the correct behaviour, so both outcomes are accepted and the
        // one that happened is reported.
        check("balancing is offered while routing", model.canCalibrate)
        model.startCalibration()
        check("it starts in the countdown", model.isCalibrating)
        await waitUntil(
            "it reaches the listening phase",
            { if case .listening = model.calibrationPhase { true } else { false } },
            timeout: 8)
        await waitUntil(
            "it finishes on its own",
            { !model.isCalibrating },
            timeout: Double(RouterModel.calibrationSeconds) + 6)

        switch model.calibrationPhase {
        case .proposing:
            note(
                "proposed "
                    + model.calibrationProposals
                    .map { String(format: "%+.1f dB", $0.change) }
                    .joined(separator: ", "))
            check(
                "every proposal names a real route",
                model.calibrationProposals.allSatisfy {
                    $0.id < model.activeRoutes.count
                })
            // Nothing is applied without being shown first: a tool that moves
            // somebody's faders silently is one they stop trusting the first
            // time it is wrong.
            let before = model.faderDecibels(forRouteAt: 0)
            model.cancelCalibration()
            check("discarding changes nothing", model.faderDecibels(forRouteAt: 0) == before)
        case .failed(let message):
            note("did not conclude: \(message)")
            check("the failure says why", !message.isEmpty)
            model.cancelCalibration()
        default:
            check("it ended in a state that says something", false)
        }
        check("it is back to idle", model.calibrationPhase == .idle)

        try section("named buses")
        // The two mixes have existed since monitoring became a second mix
        // rather than a sidetone. What did not exist was the vocabulary: the
        // interface showed a fader, and another fader with a headphone symbol,
        // and nothing said one of them is what other applications capture.
        let buses = model.buses
        check("there is at least the send", !buses.isEmpty)
        note(buses.map { "\($0.letter) \($0.deviceName)" }.joined(separator: " · "))
        check("every bus is lettered", buses.allSatisfy { !$0.letter.isEmpty })
        check("no two buses share a letter", Set(buses.map(\.letter)).count == buses.count)
        // Exactly one bus follows the master, and it is the one going out. The
        // monitor must not, or muting what the far end hears would stop
        // somebody hearing their own voice.
        check("exactly one bus follows the master", buses.filter(\.followsMaster).count == 1)
        check(
            "and it is not the monitor",
            buses.first(where: \.followsMaster)?.id != model.monitorDeviceUID
                || model.monitorDeviceUID == nil)

        if model.monitorOptions.isEmpty {
            note("no second output on this machine — one bus only")
        } else if let second = model.monitorOptions.first(where: {
            $0.uid != model.selectedDestinationUID
        }) {
            let previous = model.monitorDeviceUID
            model.monitorDeviceUID = second.uid
            await waitUntil("the monitor came up", { !model.isBusy }, timeout: 15)
            let two = model.buses
            check("choosing a monitor makes a second bus", two.count == 2)
            check("they are A and B", Set(two.map(\.letter)) == ["A", "B"])
            check(
                "the monitor is the one you hear",
                two.first { $0.id == second.uid }?.kind == .monitor)
            model.monitorDeviceUID = previous
            await waitUntil("and it went back", { !model.isBusy }, timeout: 15)
        }

        try section("sources rather than wires")
        // A stereo source is two routes, and it used to be two strips: two
        // faders, two mutes and two solo buttons for one microphone. Worse, the
        // balance pass measured each channel separately and proposed a gain for
        // each, so applying it to a stereo source would have pulled the image
        // apart.
        let groups = model.sourceGroups
        note("\(model.activeRoutes.count) route(s) in \(groups.count) source(s)")
        check(
            "every route belongs to exactly one source",
            groups.flatMap(\.routes).count == model.activeRoutes.count)
        check("no source is empty", groups.allSatisfy { !$0.routes.isEmpty })
        check("sources are distinct", Set(groups.map(\.uid)).count == groups.count)

        if let group = groups.first, group.routes.count > 1 {
            // The property that matters: every channel of a source moves
            // together, because moving one side of a stereo pair is not a
            // volume change.
            model.setFaderDecibels(-9, for: group)
            await pause(0.2)
            let each = group.routes.map { model.faderDecibels(forRouteAt: $0) }
            check("one fader moves every channel of its source", each.allSatisfy { $0 == -9 })
            model.setFaderDecibels(0, for: group)

            model.setMuted(true, for: group)
            check("one mute silences every channel", model.isMuted(group))
            check(
                "and no channel is left behind",
                group.routes.allSatisfy { model.routeMutes[$0] })
            model.setMuted(false, for: group)
            check("unmuting restores every channel", !model.isMuted(group))
        } else {
            note("no multi-channel source to exercise grouping against")
        }

        try section("per-application taps")
        // One tap per application rather than one for all of them, which is
        // what makes Discord and Spotify separable at all.
        if model.capturedAppBundleIDs.count > 1 {
            let owners = Set(
                model.activeRoutes.compactMap { model.application(of: $0)?.bundleID })
            check("each captured application has its own source", owners.count > 1)
            note("\(owners.count) application sources")
        } else {
            note("fewer than two applications captured — separation not exercised")
        }

        try section("ducking")
        // The rule that matters more than any other: it must never touch the
        // microphone. A ducker that reached the voice would be a gate keyed off
        // a classifier that reports twice a second, and it would cut the front
        // of every word.
        model.isDucking = true
        await pause(0.5)
        check("no rebuild was needed", model.isRunning && !model.isBusy)
        check("no error was reported", model.lastError == nil)
        check(
            "no microphone route is marked duckable",
            !model.activeRoutes.contains {
                $0.isDuckable && $0.source.deviceUID == model.selectedSourceUID
            })
        note("\(model.activeRoutes.filter(\.isDuckable).count) duckable route(s)")
        model.isDucking = false
        check("switching it off changed nothing else", model.isRunning && !model.isBusy)

        try section("idle cost")
        // With the panel closed and nothing switched on, none of the analysis
        // machinery should exist and the IO thread should not be folding a bus
        // for nobody.
        model.isAnalysisVisible = false
        model.isAutoLevelling = false
        model.isDucking = false
        await pause(0.4)
        check("nothing is being analysed when nothing asked", model.analysisIsIdle)
        model.isAnalysisVisible = true
        await pause(0.4)
        check("and it comes back when the panel opens", !model.analysisIsIdle)

        // The menu bar glyph, which is the one thing that runs whether or not
        // anybody is using this application. It used to be rebuilt twice a
        // second forever — an image, locked, drawn into and unlocked — to
        // produce the same pixels. With no route running there is no level, so
        // there is nothing it could draw differently however long it waits.
        //
        // Measured over a window that spans several ticks of its own timer, or
        // "no redraws" would only mean the window was shorter than half a
        // second.
        let wasRunning = model.isRunning
        if wasRunning { model.stop() }
        await waitUntil("the route is down to measure idle", { !model.isRunning }, timeout: 12)
        // A full tick of the mark's own timer before the window opens. Going
        // from running to idle *is* a change — the dot was showing a level and
        // now there is none — so exactly one redraw is correct there, and
        // counting it would be counting the thing working. Measured: without
        // this, one redraw every time.
        await pause(0.7)
        let redrawsBefore = StatusItemController.redraws
        await pause(2.0)
        let idleRedraws = StatusItemController.redraws - redrawsBefore
        note("\(idleRedraws) menu bar redraw(s) in 2 s idle, after the change to idle")
        check("the menu bar mark is not redrawn while nothing changes", idleRedraws == 0)
        if wasRunning {
            model.start()
            await waitUntil("and routing came back", { model.isRunning }, timeout: 15)
        }

        try await checkStartCost(model: model)
        try await checkPollCost(model: model)

        try section("automatic levelling")
        let trimBefore = model.inputDecibels
        model.isAutoLevelling = true
        await pause(upTo: 1.5, until: { model.isRunning && !model.isBusy })
        check("no rebuild was needed to engage it", model.isRunning && !model.isBusy)
        // In a quiet room it must hold still. That is the entire difference
        // between this and the AGC everybody switches off: with no speech there
        // is no evidence about level, so there is nothing to act on.
        if !model.heardVerdict.isSpeech {
            check("it holds still with no speech to act on", model.autoLevelIsWaiting)
            check("and has not moved the trim", model.inputDecibels == trimBefore)
            note("room is quiet — convergence not exercised here, it is unit tested")
        } else {
            note(
                String(
                    format: "speech present, offset %+.1f dB", model.autoLevelOffset))
            check("the correction stayed inside its limit", !model.autoLevelIsAtLimit)
        }
        // The trim has to remain a control while the loop is running. Its base
        // was captured once, when the loop was switched on, and every tick sets
        // the trim to base plus the loop's offset — so a drag was overwritten
        // on the next tick, and in a quiet room, where the offset is zero, it
        // went back to exactly where it had been. The slider sprang.
        //
        // Held across several ticks rather than sampled once: the loop runs at
        // the poll rate, and a reading taken before its next tick would pass
        // against the broken version too.
        let chosen = model.inputDecibels - 4
        model.inputDecibels = chosen
        await pause(1.0)
        note(
            String(
                format: "trim set to %+.1f dB by hand, reads %+.1f dB after a second",
                chosen, model.inputDecibels))
        check(
            "a trim moved by hand is not pulled back by the loop",
            abs(model.inputDecibels - chosen) < 0.5)

        // Switching it off keeps whatever level it settled on rather than
        // snapping back: the point was to find a good trim, and throwing that
        // away the moment somebody disengages would undo the work.
        let settled = model.inputDecibels
        model.isAutoLevelling = false
        await pause(0.3)
        check("switching it off keeps the level it settled on", model.inputDecibels == settled)
        check("routing continues without it", model.isRunning && !model.isBusy)
        model.inputDecibels = trimBefore

        try section("push to talk")
        // The property that matters is that arming it is safe: silence has to
        // be the resting state, or somebody broadcasts a room they were sure
        // was muted.
        let muteBefore = model.isInputMuted
        model.isPushToTalkEnabled = true
        check("arming it mutes immediately", model.isInputMuted)
        check("and it starts closed", !model.isPushToTalkHeld)
        check(
            "it got a shortcut",
            model.activeShortcuts[.pushToTalk] != nil
                || model.hotkeyFailures.contains { $0.contains("talk") })
        if let shortcut = model.activeShortcuts[.pushToTalk] {
            note("bound to \(shortcut.displayName)")
            // A badge with nothing in it is what an unnamed key code looks
            // like, and F13 upwards produce no character through the layout —
            // so this said nothing at all until they were named.
            check("the shortcut can be written down", !shortcut.displayName.isEmpty)
        }
        model.isPushToTalkEnabled = false
        // Disarming has to restore what the mute was, not leave somebody muted
        // by a feature they just switched off.
        check("disarming restores the previous mute", model.isInputMuted == muteBefore)

        try section("direct monitoring")
        if let monitor = model.monitorOptions.first {
            let routesBefore = model.activeRoutes.count
            model.monitorDeviceUID = monitor.uid
            await waitUntil("the monitor came up", { !model.isBusy }, timeout: 12)
            if let error = model.lastError { note("the monitor said: \(error)") }
            check("no error was reported", model.lastError == nil)
            check("still routing", model.isRunning)
            check("monitoring added routes", model.activeRoutes.count > routesBefore)
            note("\(routesBefore) → \(model.activeRoutes.count) routes on \(monitor.name)")
            note(
                String(
                    format: "%.1f ms behind", model.monitorLatencyMilliseconds))
            // The whole claim of direct monitoring is that it is one cycle, not
            // a software round trip. Anything past about fifteen milliseconds
            // and a person hears their own voice as an echo.
            check(
                "the monitor is genuinely direct",
                model.monitorLatencyMilliseconds > 0
                    && model.monitorLatencyMilliseconds < 30)

            // The master is the level going to the far end. Muting it must not
            // take away the ability to hear yourself, which is the one thing
            // that would make monitoring useless exactly when it is needed.
            let cyclesBeforeMute = model.cycleCountForDiagnostics
            model.isOutputMuted = true
            await pause(0.4)
            check("muting the master did not rebuild", model.isRunning && !model.isBusy)
            check("audio kept flowing", model.cycleCountForDiagnostics > cyclesBeforeMute)
            model.isOutputMuted = false

            // And its own fader moves without a rebuild.
            let cyclesBeforeGain = model.cycleCountForDiagnostics
            model.monitorDecibels = -18
            await pause(0.4)
            check("the monitor level reads back", model.monitorDecibels == -18)
            check(
                "changing it did not interrupt audio",
                model.cycleCountForDiagnostics > cyclesBeforeGain && !model.isBusy)

            // A second mix, not a sidetone. Every source can go to it at its
            // own level — music loud in your ears and quiet on the stream —
            // which is what every tool praised for this is praised for.
            let mainRoutes = model.activeRoutes.count
            if let group = model.sourceGroups.first {
                let before = model.monitorSendDecibels(of: group)
                note(
                    String(
                        format: "%@ monitor send %.1f dB", model.sourceLabel(for: group), before
                    ))
                check(
                    "the microphone is in the monitor by default",
                    before > RouterModel.minimumDecibels)
                let cyclesBefore = model.cycleCountForDiagnostics
                model.setMonitorSend(-15, for: group)
                await pause(0.4)
                check("its send moved", model.monitorSendDecibels(of: group) == -15)
                check(
                    "and moving it did not interrupt audio",
                    model.cycleCountForDiagnostics > cyclesBefore && !model.isBusy)
                model.setMonitorSend(before, for: group)
                await waitUntil("it settled", { !model.isBusy }, timeout: 12)
            }
            // Everything else starts off it, because whether the music should
            // also be in your ears is a decision rather than a default.
            for group in model.sourceGroups.dropFirst() {
                check(
                    "\(model.sourceLabel(for: group)) starts off the monitor",
                    model.monitorSendDecibels(of: group) <= RouterModel.minimumDecibels)
            }
            note("\(mainRoutes) route(s) with the monitor attached")

            model.monitorDeviceUID = nil
            await waitUntil("monitoring came back out", { !model.isBusy }, timeout: 12)
            check("routing continues without it", model.isRunning)
            check(
                "the extra routes went away", model.activeRoutes.count == routesBefore)

            // Handed on the way it was received, because a monitor is the one
            // thing this section attaches that can fail to start — a display's
            // audio endpoint is the ordinary case, and attaching one takes the
            // whole route down rather than only the second mix. Taking it back
            // out does not bring the route back: `restartIfRunning` returns
            // immediately while nothing is running, so the route stays down for
            // every section after this one.
            //
            // Measured: three consecutive runs on this machine where the note
            // above read "1 → 0 routes on PG32UCDM" — a display's audio
            // endpoint — after which every remaining section ran against a dead
            // route. It surfaced two minutes later as twelve failures in the
            // echo canceller and the preset, which read like the canceller
            // misbehaving and are nothing of the sort. The section that broke
            // the route is the section that has to say so and put it back.
            if !model.isRunning {
                note("the monitor took the route down with it — starting again without one")
                await bringRoutingBack(model)
                check("and the route comes back without a monitor", model.isRunning)
            }

            // And now the case above, on purpose.
            //
            // A monitor is an additional output, so one that will not start
            // must cost the monitor and nothing else. Asserting that needs an
            // output that reliably refuses, and the two displays that produced
            // the original measurement — three runs of `1 → 0 routes on
            // PG32UCDM` — are not always on this machine, which is exactly why
            // the defect went unfixed while it was known.
            //
            // A private aggregate is always here: CoreAudio will not have one
            // as a member of another, so its channels never appear in the
            // routed aggregate and the start fails resolving the routes into
            // it. That is the same failure a display's endpoint produces, at
            // the same point, and it needs no particular hardware.
            //
            // Only while this section is being tested. A skimmed section
            // records nothing, and this is two real route starts — measured at
            // eight seconds of a run nobody asked it of.
            if inWantedSection,
                let decoy = try? AggregateDevice(
                    name: "YunAudio Unstartable Monitor",
                    subDevices: [.init(uid: monitor.uid, driftCompensation: false)],
                    clockMasterUID: monitor.uid)
            {
                model.refreshDevices()
                let decoyIsListed = model.outputDevices.contains { $0.uid == decoy.uid }
                if decoyIsListed {
                    let mainMix = model.activeRoutes.count
                    model.monitorDeviceUID = decoy.uid
                    // Longer than the twelve above: a monitor that fails is two
                    // starts rather than one, and the first of them can be a
                    // device taking twelve seconds to say no.
                    await waitUntil("the start finished", { !model.isBusy }, timeout: 30)
                    check(
                        "the main mix survives a monitor that will not start", model.isRunning)
                    check(
                        "and keeps every route it had",
                        model.activeRoutes.count == mainMix)
                    check(
                        "no fader is left pointing at a route that does not exist",
                        model.routeGains.count == model.activeRoutes.count
                            && model.routeMutes.count == model.activeRoutes.count)
                    check("the monitor sends went with it", model.monitorRoutesAreConsistent)
                    // The point of the whole exercise: a monitor that vanishes
                    // with nothing said about it is the defect in another form.
                    check("monitoring took itself off", model.monitorDeviceUID == nil)
                    check("and the interface names the output", model.droppedMonitorName != nil)
                    check(
                        "the message names it too",
                        model.droppedMonitorName.map { model.lastError?.contains($0) ?? false }
                            ?? false)
                    if let reason = model.droppedMonitorReason {
                        note("the engine said: \(reason)")
                    }
                    if let error = model.lastError { note("the user is told: \(error)") }
                    let cycles = model.cycleCountForDiagnostics
                    await pause(0.4)
                    check(
                        "and audio is still flowing",
                        model.cycleCountForDiagnostics > cycles)
                } else {
                    note("the decoy aggregate is not in the device list — skipped")
                }
                decoy.destroy()
                model.refreshDevices()
            } else {
                note("no aggregate could be built to fail with — skipped")
            }
        } else {
            note("no second output to monitor on — skipped")
        }

        try section("pitch tracking")
        // Knowing the actual fundamental is what would let a voice be moved to
        // a range rather than by an amount. Measured against the live signal:
        // in a quiet room there is no pitch to find, and reporting one would be
        // the failure worth catching.
        // Through the analyser rather than beside it: the analyser drains the
        // ring dry every fifty milliseconds, so a diagnostic that read the same
        // ring found nothing and reported it as a lack of audio. The tracker is
        // one of the analyser's outputs now, which is where it belonged.
        model.isAnalysisVisible = true
        await pause(upTo: 1.5, until: { model.analysis.pitchHertz > 0 })
        let pitch = model.analysis.pitchHertz
        note(
            pitch > 0
                ? String(format: "%.0f Hz", pitch) : "no pitch — a quiet room has none")
        check(
            "any pitch reported is inside the range it searches",
            pitch == 0
                || (Double(pitch) >= PitchTracker.lowestHertz - 1
                    && Double(pitch) <= PitchTracker.highestHertz + 1)
        )
        // A quiet room has no fundamental, and inventing one would make a
        // converter chase noise between words.
        if model.outputVerdict == .veryQuiet || model.outputVerdict == .silent {
            check("a silent room reports no pitch", pitch == 0)
        }

        try section("every stage on its own")
        // One at a time, which is how somebody actually uses these and the case
        // that was broken: the chain was only built for more than one stage, so
        // switching on just the gate — or just the compressor, or just the
        // limiter — did nothing at all and said nothing about it. Every check
        // that touched processing before this one enabled several at once.
        let effectsBefore = model.enabledEffects
        model.enabledEffects = []
        await waitUntil("the chain is empty", { !model.isBusy }, timeout: 12)
        for kind in EffectKind.allCases {
            model.enabledEffects = [kind]
            await waitUntil("\(kind.rawValue) settled", { !model.isBusy }, timeout: 14)
            check(
                "\(kind.rawValue) alone actually renders",
                model.activeEffectStages.contains(kind))
            check("\(kind.rawValue) alone kept audio running", model.isRunning)
        }
        model.enabledEffects = effectsBefore
        await waitUntil("the chain came back", { !model.isBusy }, timeout: 14)

        try section("gain reduction")
        // A compressor set wrong is completely silent about it: it sounds like
        // a compressor doing nothing, which is what it is. The meter is the
        // only way to tell, so it has to actually report.
        model.setEffect(.compressor, enabled: true)
        await waitUntil("the compressor is in the path", { !model.isBusy }, timeout: 12)
        // The figure comes from the poll, and `isBusy` clearing does not mean a
        // poll has run — the first version checked in the gap between the two
        // and found nothing.
        await waitUntil(
            "it reports a reduction figure",
            { model.gainReduction[.compressor] != nil }, timeout: 3)
        // Threshold on the floor, so anything at all is above it. A quiet room
        // may still be under it, and reporting no reduction then is the correct
        // answer rather than a failure — what is asserted is that the number is
        // real, not that it is large.
        model.setValue(-40, of: EffectKind.compressor.parameters[0], in: .compressor)
        await pause(upTo: 1.2, until: { (model.gainReduction[.compressor] ?? 0) > 0 })
        let reducing = model.gainReduction[.compressor] ?? -1
        note(String(format: "%.1f dB of reduction at a −40 dB threshold", reducing))
        check("the figure is a plausible amount", reducing >= 0 && reducing < 60)
        model.setValue(
            EffectKind.compressor.parameters[0].defaultValue,
            of: EffectKind.compressor.parameters[0], in: .compressor)
        model.setEffect(.compressor, enabled: false)
        await waitUntil("it came back out", { !model.isBusy }, timeout: 12)
        // The dictionary is cleared by the poll, and `isBusy` clearing does not
        // mean a poll has run.
        await waitUntil(
            "the meter goes away with the stage",
            { model.gainReduction[.compressor] == nil }, timeout: 3)

        try section("switching channel mode while running")
        let before = model.activeRoutes.count
        model.channelMode = model.channelMode == .mono ? .stereo : .mono
        // A channel-mode change is a rebuild, not a live edit: the engine stops,
        // frees the RCU cell and makes a new one. So the cycle counter starts
        // again from zero, and comparing it against the value from before the
        // change proves nothing — it was passing only when 0.4 s had not been
        // long enough for the teardown to happen at all, and failing whenever
        // the machine was quick. Worse, carrying on while `isBusy` was still
        // set meant everything after it was talking to an engine mid-restart,
        // which is what made the recording refuse to start.
        await waitUntil("the rebuild settled", { !model.isBusy }, timeout: 8)
        check("still running", model.isRunning)
        check("the route set changed", model.activeRoutes.count != before || before > 0)
        // Audio flowing is then a claim about the new graph, which is the only
        // one worth making: the counter has to be advancing now.
        let cyclesAfterRebuild = model.cycleCountForDiagnostics
        await pause(0.4)
        check(
            "audio is flowing through the rebuilt graph",
            model.cycleCountForDiagnostics > cyclesAfterRebuild)

        try section("recording")
        check("recording is offered while routing", model.isRunning)
        // Listening before the button is pressed, because `recordStart` and
        // `recordStop` were names in `ScriptHost.Event` that nothing raised.
        // The scripting help lists every case, and `installEvents` refuses an
        // unknown name so that a mistyped handler cannot silently never fire —
        // so these two were accepted, advertised, and never called. Asserted
        // here rather than in the scripting section because recording needs a
        // route, and this is where there is certainly one.
        let scriptBeforeRecording = model.residentScript
        model.residentScript = """
            yun.on('recordStart', function (e) { yun.log('recordStart ' + e.file); });
            yun.on('recordStop', function (e) { yun.log('recordStop ' + e.seconds); });
            """
        check("a script can ask about recording", model.residentScriptError == nil)
        model.toggleRecording()
        check("the recording started", model.isRecording)
        check("no error was reported", model.lastError == nil)
        let file = model.recordingURL
        check("a file was named", file != nil)
        await pause(upTo: 2.0, until: { model.recordingSeconds > 0.5 })
        check("the elapsed time is advancing", model.recordingSeconds > 0.5)
        // Pausing has to stop the clock as well as the writing, or the elapsed
        // time claims audio that is not in the file.
        //
        // Not measured from the instant of the pause: whatever is already in
        // the ring keeps being written, and it should — those frames were
        // captured before anybody pressed pause, and throwing them away would
        // clip the end of every sentence somebody paused after. So the backlog
        // is allowed to flush first, and what is asserted is that it then
        // stops, which is the actual claim.
        model.toggleRecordingPause()
        check("it paused", model.isRecordingPaused)
        await pause(0.6)
        let atPause = model.recordingSeconds
        await pause(1.0)
        check(
            "the elapsed time stops while paused",
            abs(model.recordingSeconds - atPause) < 0.02)
        note(
            String(
                format: "%.2fs after the backlog flushed, %.2fs a second later",
                atPause, model.recordingSeconds))
        model.toggleRecordingPause()
        check("it resumed", !model.isRecordingPaused)
        await pause(0.8)
        check("and the elapsed time moves again", model.recordingSeconds > atPause + 0.3)

        model.toggleRecording()
        check("the recording stopped", !model.isRecording)
        check("stopping clears the pause", !model.isRecordingPaused)
        note("script said: " + model.scriptLog.joined(separator: ", "))
        check(
            "starting the recording reached the script",
            model.scriptLog.contains { $0.hasPrefix("recordStart ") })
        check(
            "and stopping it did",
            model.scriptLog.contains { $0.hasPrefix("recordStop ") })
        // The payload is the point of the event: a script that is told a
        // recording finished and not which file has been told nothing it can
        // act on.
        check(
            "the file it names is the one that was written",
            model.scriptLog.contains { $0 == "recordStart " + (file?.path ?? "—") })
        model.residentScript = scriptBeforeRecording

        try section("stems")
        // A file per source alongside the mix. What cannot be recovered from a
        // mix at any price is who said what, so this is the recording that
        // matters for anything edited afterwards.
        model.recordsStems = true
        model.toggleRecording()
        check("it started", model.isRecording)
        check("no error was reported", model.lastError == nil)
        let stems = model.stemURLs
        check("a file was named per source", stems.count == model.sourceGroups.count)
        note(
            "\(stems.count) stem(s): \(stems.map(\.lastPathComponent).joined(separator: ", "))")
        // Named after the source rather than numbered: three files called
        // "YunAudio 01.12.33" is not something anybody can sort out later.
        check(
            "each is named after its source",
            zip(stems, model.sourceGroups).allSatisfy { url, group in
                guard let route = model.representative(of: group) else { return false }
                let title = Recorder.sanitised(model.routeTitle(route))
                return title.isEmpty || url.lastPathComponent.contains(title)
            })
        // Until every stem has enough in it to assert on, rather than two
        // seconds whichever way it goes. The size below is the real check.
        //
        // The elapsed time is waited for as well, and that is not belt and
        // braces: a stereo stem passes 100 kB in about a quarter of a second,
        // so the size alone stopped the recording after 0.35 s — measured — and
        // the assertion at the bottom of this section then read a duration that
        // had survived the stop perfectly well and was simply shorter than the
        // half second it was comparing against. It failed in a full run and
        // passed on its own for no better reason than which one wrote its
        // hundred kilobytes first.
        await pause(
            upTo: 4.0,
            until: {
                model.recordingSeconds > 0.8
                    && stems.allSatisfy { url in
                        let size =
                            (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                                .size]
                            as? Int ?? 0
                        return size > 100_000
                    }
            })
        let secondsBeforeStemStop = model.recordingSeconds
        model.toggleRecording()
        note(
            String(
                format: "stems ran %.2fs; %.2fs after the stop",
                secondsBeforeStemStop, model.recordingSeconds))
        await pause(0.6)
        for url in stems {
            let size =
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int ?? 0
            check("\(url.lastPathComponent) holds audio", size > 100_000)
            try? FileManager.default.removeItem(at: url)
        }
        check("no stem dropped samples", model.engineStemDrops == 0)
        if let mix = model.recordingURL { try? FileManager.default.removeItem(at: mix) }
        model.recordsStems = false
        // The duration has to survive the stop. Reading it after releasing the
        // recorder returned zero, so the elapsed time snapped to 00:00 at
        // exactly the moment anyone would look at it.
        //
        // Against what it read a moment before the stop rather than against a
        // fixed half second, which is the claim: nothing was lost by releasing
        // the recorder. A constant here is a second assertion about how long
        // the wait above happened to run, and it was that second assertion —
        // never this one — that was failing.
        check("there was an elapsed time to survive", secondsBeforeStemStop > 0.5)
        check(
            "the elapsed time survived the stop",
            model.recordingSeconds >= secondsBeforeStemStop)

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

        try section("stems survive a route edit")
        // The bug this catches was live: rebuilding the graph dropped the stem
        // assignment, so moving one cable during a recording left every file
        // open, silent and still counting time with nothing saying so.
        model.recordsStems = true
        model.toggleRecording()
        let editedStems = model.stemURLs
        if editedStems.isEmpty {
            note("no stems started — skipped")
            model.toggleRecording()
        } else {
            await pause(1.0)
            let before = editedStems.map { size(of: $0) }
            // A fader or a mute is not enough — those go through the command
            // queue. Adding a cable is what rebuilds the graph, and it is the
            // ordinary thing somebody does mid-session.
            // A source channel that is not routed yet, into a destination
            // channel that already is. A stereo pair usually has both
            // destination channels taken, so it is the source side that has
            // room — the Seiren publishes three inputs and two are in use.
            let existing = model.activeRoutes.first
            let spare = existing.flatMap { route -> Route? in
                let used = Set(
                    model.activeRoutes.filter { $0.destination == route.destination }
                        .map(\.source.channel))
                guard
                    let channel = (0..<(model.selectedSource?.inputChannels ?? 0))
                        .first(where: { !used.contains($0) })
                else { return nil }
                return Route(
                    source: ChannelRef(
                        deviceUID: route.source.deviceUID, channel: channel),
                    destination: route.destination)
            }
            let routesBefore = model.activeRoutes.count
            if let spare {
                model.connect(source: spare.source, destination: spare.destination)
                check("the graph was rebuilt", model.activeRoutes.count > routesBefore)
            } else {
                note("no spare channel — the rebuild was not exercised")
            }
            await pause(1.5)
            model.toggleRecording()
            await pause(0.6)
            let after = editedStems.map { size(of: $0) }
            check(
                "every stem kept growing across the edit",
                zip(before, after).allSatisfy { $1 > $0 + 10_000 })
            note("stem sizes \(before) → \(after)")
            // Only the cable just added, put back the way it was. Disconnecting
            // the whole destination would pull the stems' own routes with it.
            if let spare {
                model.disconnectRoute(source: spare.source, destination: spare.destination)
            }
            for url in editedStems { try? FileManager.default.removeItem(at: url) }
            if let mix = model.recordingURL { try? FileManager.default.removeItem(at: mix) }
        }
        model.recordsStems = false

        try section("transcription")
        if let reason = model.transcriptionUnavailableReason {
            // Not a failure. On a system without the model this is the correct
            // behaviour, and the point of the check is that it says so rather
            // than offering a control that does nothing.
            note("unavailable: \(reason)")
            model.startTranscribing()
            check("it refuses rather than pretending", !model.isTranscribing)
            check("and it says why", model.transcriptionError != nil)
        } else {
            model.startTranscribing()
            check("it started", model.isTranscribing)
            check("no error was reported", model.transcriptionError == nil)
            // One per source is the whole mechanism: attribution is the wiring
            // rather than a guess about who was speaking.
            check(
                "one tap per source",
                model.engineTranscriptTaps == model.sourceGroups.count)
            await pause(2.0)
            check("it is still going", model.isTranscribing)
            check("still no error", model.transcriptionError == nil)
            model.stopTranscribing()
            check("it stopped", !model.isTranscribing)
            await pause(0.5)
            check("the tap closed", model.engineTranscriptTaps == 0)
            note("\(model.transcript.count) line(s) from silence")
            // Starting again after stopping has to work; the rings are freed on
            // stop and a stale index would be a use-after-free rather than a
            // quiet nothing.
            model.startTranscribing()
            check("it starts again", model.isTranscribing)
            model.stopTranscribing()
        }

        try section("switching the echo canceller on while running")
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
            // Taking the canceller out is a restart, and a restart that fails
            // leaves the route down for good: nothing else in the run asks for
            // it back, because every later setting goes through
            // `restartIfRunning`, which returns immediately while nothing is
            // running. The three checks above are the honest report of that;
            // the four in the section below are not, and neither are the twenty
            // sections after those. Whichever section breaks the route is the
            // section that has to say so and put it back.
            if !model.isRunning {
                note("the route did not survive the canceller leaving — starting it again")
                await bringRoutingBack(model)
                check("and it can be started again", model.isRunning)
            }
        }

        try section("applying a preset while running")
        // One restart per preset, not one per property. Every field a preset
        // sets restarts the route on its own, so this used to tear the audio
        // down and rebuild it three times for a single click.
        let cyclesBeforePreset = model.cycleCountForDiagnostics
        model.apply(.recording)
        await pause(upTo: 8.0, until: { model.isRunning && !model.isBusy })
        check("still running after a preset", model.isRunning)
        check("no error after a preset", model.lastError == nil)
        // Sampled after the rebuild, not before it. A preset that changes a
        // sample rate or a buffer is a rebuild, and a rebuild frees the RCU
        // cell the counter lives in and makes a new one — so the count starts
        // again from zero and comparing it with the value from before the
        // preset compares two different counters. It passed only while the
        // route happened to have restarted moments earlier and had not yet
        // counted past it. Measured on this machine: 101 cycles before the
        // preset and 8 after it, reported as "audio came back" failing on a
        // route that was running perfectly. The same mistake is written up in
        // "switching channel mode while running".
        //
        // The wait is eight seconds rather than one and a half for the other
        // half of it: a preset that moves a sample rate is a real rebuild, and
        // one and a half seconds was not always enough for it, so the counter
        // was sometimes read at zero while the new graph was still being built.
        let cyclesAfterPreset = model.cycleCountForDiagnostics
        await pause(0.4)
        check(
            "audio came back",
            model.cycleCountForDiagnostics > cyclesAfterPreset)
        note("\(cyclesBeforePreset) cycles before the preset, \(cyclesAfterPreset) after it")
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

        try section("what a scene actually changes")
        // The defect this section exists for. The four scenes carried a sample
        // rate, a buffer and one isolation flag, and deliberately left the
        // processing chain alone — so pressing "Noisy room" instead of "Voice
        // chat" moved a buffer size and was otherwise inaudible. Every check
        // here is written so that a scene which changes nothing cannot pass it.
        let declared = RoutePreset.builtIn.map { $0.effectKinds ?? [] }
        check("every scene declares a chain", declared.allSatisfy { !$0.isEmpty })
        check(
            "and no two scenes declare the same one",
            Set(declared).count == RoutePreset.builtIn.count)

        var installed: [Set<EffectKind>] = []
        var sceneLatency: [String: Double] = [:]
        for preset in RoutePreset.builtIn {
            model.apply(preset)
            // Settling is the model's business; coming up is the machine's.
            // Kept apart because a scene that asks for the echo canceller
            // cannot start at all on hardware the canceller will not take, and
            // that is a fact about the machine rather than about the scene.
            await waitUntil("\(preset.name) settled", { !model.isBusy }, timeout: 15)
            // Brought back up with *this* scene's settings if something earlier
            // left the route down. After the apply rather than before it: a
            // retry ahead of the apply would use the previous scene's devices
            // and canceller, so one scene this machine cannot run would take
            // every scene after it down as well — which is exactly what a
            // section written to compare four scenes must not do.
            await bringRoutingBack(model)
            let wanted = preset.effectKinds ?? []
            check(
                "\(preset.name) put its stages in the model",
                model.enabledEffects == wanted)
            // A rebuilt chain comes up at each stage's own defaults, and
            // nothing was putting the stored values back — so a scene could
            // carry a gate threshold, display it, and never send it anywhere.
            for (key, value) in (preset.effectValues ?? [:]).sorted(by: { $0.key < $1.key }) {
                check("\(preset.name) restored \(key)", model.effectValues[key] == value)
            }
            check(
                "\(preset.name) set its loudness target",
                preset.loudnessTarget == model.loudnessTarget.rawValue)
            check("\(preset.name) reads as the active scene", model.matches(preset))

            guard model.isRunning else {
                note("\(preset.name) would not come up here — its chain was not measured")
                continue
            }
            // The engine's list rather than the model's opinion of it: a chain
            // that failed to build is the one thing the model cannot see.
            check(
                "\(preset.name) built exactly those stages",
                Set(model.activeEffectStages) == wanted)
            installed.append(Set(model.activeEffectStages))
            sceneLatency[preset.name] = model.addedLatencyMilliseconds
            note(
                "\(preset.name): "
                    + model.activeEffectStages.map(\.rawValue).joined(separator: " → ")
                    + String(format: ", %.1f ms", model.addedLatencyMilliseconds))
        }
        if installed.count > 1 {
            check(
                "no two scenes left the same chain running",
                Set(installed).count == installed.count)
        } else {
            note("fewer than two scenes came up — the chains were not compared in the engine")
        }
        // The one number here that comes from the Audio Units themselves rather
        // than from anything this application stored. A scene that really
        // installed a different chain costs a different amount of latency, and
        // the recording scene is the floor by construction: a limiter, and
        // nothing else. If the chains were secretly identical this is what
        // would say so.
        if let heavy = sceneLatency[RoutePreset.noisyRoom.name],
            let bare = sceneLatency[RoutePreset.recording.name]
        {
            check("a heavier scene costs more latency than the bare one", heavy > bare)
        }

        model.apply(.voiceChat)
        await waitUntil("the call scene came back", { !model.isBusy }, timeout: 15)
        await bringRoutingBack(model)
        // And a scene has to stop claiming to describe what is running the
        // moment somebody edits it, or the highlight on the button is
        // decoration. A knob rather than a stage on purpose: moving one costs
        // no rebuild, so this measures the comparison and not the restart.
        if let threshold = EffectKind.gate.parameters.first(where: { $0.id == "threshold" }) {
            let before = model.value(of: threshold, in: .gate)
            model.setValue(before + 5, of: threshold, in: .gate)
            check("moving one of its knobs ends the match", !model.matches(.voiceChat))
            model.setValue(before, of: threshold, in: .gate)
            check("and putting it back restores it", model.matches(.voiceChat))
        }

        // Handed back neutral. A scene now carries auto-levelling and ducking,
        // and a gain rider left running would move the input trim underneath
        // every measurement below this — the bit-exactness check included.
        model.isAutoLevelling = false
        model.isDucking = false
        model.inputDecibels = 0

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
        // It used to read "fewer than doing them loose", and loose was two or
        // three. A restart asked for while the engine queue is busy is now
        // recorded and carried out once when it comes free rather than being
        // dropped, so three loose edits landing inside one rebuild coalesce
        // into that rebuild as well. What is left to assert is that batching is
        // never worse — the guarantee it actually offers is the *one*, which
        // the line above checks and loose editing still cannot promise.
        check("and never more than doing them loose", batched <= unbatched)
        await waitUntil("the batch settled", { !model.isBusy }, timeout: 10)
        check("routing survived both", model.isRunning)

        try section("what survives the clock lock giving way")
        // The one rebuild nobody asks for. When the driver misses an anchor
        // deadline the engine brings the route back with drift correction on,
        // and it used to bring it back from four remembered fields — the two
        // devices, the routes and the buffer size — with every other argument
        // of `start` going to its default. So the entire processing chain
        // disappeared, and with it the monitor mix, the captured applications
        // and the requested sample rate.
        //
        // Nothing said so, and nothing could: the model still held all of them,
        // so the interface went on showing a chain that was no longer rendering,
        // and `isRunning` was still true because the model was never told. It
        // turned up as a scene that "put its stages in the model" and then built
        // none of them, which reads like the scene being at fault.
        model.apply(.noisyRoom)
        await waitUntil("a scene with a chain settled", { !model.isBusy }, timeout: 15)
        await bringRoutingBack(model)
        // Whether the route came up holding the driver's clock is not decided by
        // this application: the anchor property is read from the driver, and a
        // driver another copy of this app is talking to can answer that it does
        // not lock. That is worth one retry rather than a silently skipped
        // check — `allowClockLockRetry` runs at every start, so a fresh one is
        // a fresh chance at the lock.
        var armed = model.holdsClockLock
        if !armed {
            model.stop()
            await waitUntil("it went down to try again", { !model.isBusy }, timeout: 10)
            model.start()
            await waitUntil("and came back", { model.isRunning && !model.isBusy }, timeout: 15)
            armed = model.holdsClockLock
        }
        if model.isRunning {
            let stagesBefore = Set(model.activeEffectStages)
            let latencyBefore = model.addedLatencyMilliseconds
            let routesBefore = model.activeRoutes.count
            // Said out loud because none of it was reported anywhere before, and
            // the three answers mean three different runs: a driver that cannot
            // anchor never locks and never recovers; a lock already lost has
            // already done whatever it was going to do; and a lock held is the
            // only state in which the assertions below mean anything.
            let anchoring =
                ClockAnchorPublisher(driverDeviceUID: ClockAnchorPublisher.driverDeviceUID)?
                .driverSupportsClockLocking ?? false
            note(
                "driver anchors: \(anchoring), holds the lock: \(armed), "
                    + "locked now: \(model.isClockLocked), "
                    + "lock already lost: \(model.clockLockFailed)")
            check("there is a chain to lose", !stagesBefore.isEmpty)
            if stagesBefore.isEmpty {
                note("no chain came up at all — the recovery had nothing to preserve")
            } else if await model.forceClockLockRecovery() {
                // The recovery does not go through `isBusy` — it happens behind
                // the model's back — so there is nothing to wait for except the
                // poll that refreshes the reported rate.
                await pause(1.5)
                check("the route is still up", model.isRunning)
                check(
                    "the chain came back with it",
                    Set(model.activeEffectStages) == stagesBefore)
                check(
                    "carrying the same latency",
                    abs(model.addedLatencyMilliseconds - latencyBefore) < 0.05)
                check("and the same routes", model.activeRoutes.count == routesBefore)
                // The rebuild is only worth doing because it changes this, so a
                // recovery that left the lock claimed would be the other failure.
                check("the lock is reported as lost", model.clockLockFailed)
                note(
                    model.activeEffectStages.map(\.rawValue).joined(separator: " → ")
                        + String(format: ", %.1f ms", model.addedLatencyMilliseconds))
            } else {
                note("this route is not clock-locked — the recovery was not exercised")
            }
        }
        // Handed on locked again. The recovery deliberately gives the clock back
        // to the HAL, and every measurement below — bit-exactness most of all —
        // would otherwise be made against a resampled path.
        model.stop()
        await waitUntil("it went down", { !model.isRunning && !model.isBusy }, timeout: 10)
        model.start()
        await waitUntil("and came back", { model.isRunning && !model.isBusy }, timeout: 15)

        try section("processing chain")
        // Every stage has to build against the real Audio Unit. A knob wired to
        // a parameter the unit does not have fails silently — the slider moves
        // and nothing happens.
        for kind in EffectKind.allCases where kind != .voiceIsolation {
            model.setEffect(kind, enabled: true)
            // Enabling a stage rebuilds the graph, and a fixed pause lands in
            // the middle of it — the same race that made the echo canceller
            // look broken twice.
            await waitUntil(
                "\(kind.rawValue) came up", { !model.isBusy && model.isRunning },
                timeout: 10)
            check("\(kind.rawValue) built and audio kept flowing", model.isRunning)
            check("no error from \(kind.rawValue)", model.lastError == nil)
            for parameter in kind.parameters {
                model.setValue(parameter.defaultValue, of: parameter, in: kind)
                check(
                    "\(kind.rawValue).\(parameter.id) reads back",
                    abs(model.value(of: parameter, in: kind) - parameter.defaultValue)
                        < 0.001)
            }
            model.setEffect(kind, enabled: false)
            await waitUntil(
                "\(kind.rawValue) came back out", { !model.isBusy && model.isRunning },
                timeout: 10)
        }
        check("routing survived the whole chain", model.isRunning)

        try section("processing chain swapped live")
        // The claim being tested is that changing the chain no longer restarts
        // the route. Measured before it was made true: one stage cost about
        // 880 ms inside the engine, 645 of it in `AudioDeviceStart`, and
        // seconds end to end — seconds of silence for one switch.
        //
        // "Still running" is not enough to show it, because a restart also ends
        // with the route running. The witness is the IO cycle counter: it lives
        // in the RCU cell, which a live swap keeps and a restart frees and
        // makes again. So a restart shows up as the counter going backwards,
        // and audio actually flowing through the new graph shows up as it going
        // forwards. Both are asserted for every one of the eleven stages, on
        // and off.
        let chainBefore = model.enabledEffects
        model.enabledEffects = []
        await waitUntil("the chain is empty to start from", { !model.isBusy }, timeout: 12)

        var restartedOn: [String] = []
        var stalledOn: [String] = []
        var missingFrom: [String] = []
        var stoppedOn: [String] = []
        let swapsBegan = Date()
        for kind in EffectKind.allCases {
            for wanted in [true, false] {
                let cyclesBefore = model.cycleCountForDiagnostics
                model.setEffect(kind, enabled: wanted)
                await settle(model, timeout: 12)
                let cyclesAfter = model.cycleCountForDiagnostics
                let label = "\(kind.rawValue) \(wanted ? "on" : "off")"
                if !model.isRunning { stoppedOn.append(label) }
                // Fewer cycles than before the change means the counter started
                // again, which means the cell did, which means a restart.
                if cyclesAfter < cyclesBefore { restartedOn.append(label) }
                // And the same count means nothing is pulling audio at all.
                if cyclesAfter <= cyclesBefore { stalledOn.append(label) }
                if wanted, !model.activeEffectStages.contains(kind) {
                    missingFrom.append(label)
                }
                if !wanted, model.activeEffectStages.contains(kind) {
                    missingFrom.append(label)
                }
            }
        }
        let swapSeconds = Date().timeIntervalSince(swapsBegan)
        note(
            String(
                format: "%.2fs to switch all %d stages on and off again",
                swapSeconds, EffectKind.allCases.count))
        check("the route never stopped", stoppedOn.isEmpty)
        check(
            "and never restarted: the cycle counter never went backwards", restartedOn.isEmpty)
        check("audio kept flowing across every change", stalledOn.isEmpty)
        check("the chain that ran was the one asked for", missingFrom.isEmpty)
        if !restartedOn.isEmpty { note("restarted on: " + restartedOn.joined(separator: ", ")) }
        if !missingFrom.isEmpty {
            note("wrong chain on: " + missingFrom.joined(separator: ", "))
        }

        // A knob moved off its default, so that what is asserted afterwards is
        // the stored position surviving the swap rather than the default
        // happening to match it. Read back off the unit rather than off the
        // model: the model's copy survives either way, which is precisely why
        // knobs reverting on every rebuild went unnoticed for so long.
        if let threshold = EffectKind.gate.parameters.first(where: { $0.id == "threshold" }) {
            model.setEffect(.gate, enabled: true)
            await settle(model, timeout: 12)
            model.setValue(-38, of: threshold, in: .gate)
            let set = model.renderedValue(of: threshold, in: .gate)
            check(
                "the gate's threshold reached the unit",
                set != nil && abs((set ?? 0) + 38) < 0.5)

            // Another stage beside it rebuilds the whole chain, so the gate is
            // a new unit at its own default of −45 dB unless the stored value
            // was pushed back in.
            model.setEffect(.compressor, enabled: true)
            await settle(model, timeout: 12)
            let kept = model.renderedValue(of: threshold, in: .gate)
            note(
                String(
                    format: "gate threshold across the swap: %.1f dB, default %.1f dB",
                    kept ?? .nan, threshold.defaultValue))
            check(
                "the knob position survived the swap",
                kept != nil && abs((kept ?? 0) + 38) < 0.5)
            model.setValue(threshold.defaultValue, of: threshold, in: .gate)
            model.setEffect(.compressor, enabled: false)
            model.setEffect(.gate, enabled: false)
            await settle(model, timeout: 12)
        }

        // Isolation on its own, which the loop above skips and which is the one
        // configuration that does not build a chain at all: a dedicated unit is
        // used instead, because it carries the model choice a chain cannot
        // express. The mix slider wrote only to the chain, so in the single
        // arrangement where isolation is the entire point, moving it did
        // nothing and the interface showed the new number.
        if let mix = EffectKind.voiceIsolation.parameters.first(where: { $0.id == "mix" }) {
            model.enabledEffects = [.voiceIsolation]
            await settle(model, timeout: 14)
            model.voiceIsolationMix = 62
            await settle(model, timeout: 14)
            let reached = model.renderedValue(of: mix, in: .voiceIsolation)
            note(String(format: "isolation mix on its own: %.1f%%", reached ?? .nan))
            check(
                "the isolation mix reached the unit with no chain around it",
                reached != nil && abs((reached ?? 0) - 62) < 0.5)

            // And it got there without rebuilding anything, which is what makes
            // it a knob somebody can move while listening rather than one that
            // costs a second of silence per value the drag passes through.
            //
            // Sampled rather than compared once. A single reading afterwards
            // proves nothing either way: the write is synchronous, so no time
            // has passed and the counter has not moved, and a route that *did*
            // restart would climb past the old value a moment later anyway.
            // What only a restart can produce is the counter going backwards,
            // because the cell it lives in is freed and made again.
            var counts: [UInt64] = [model.cycleCountForDiagnostics]
            for value in [70, 80, 90] as [Float] {
                model.voiceIsolationMix = value
                try? await Task.sleep(for: .milliseconds(120))
                counts.append(model.cycleCountForDiagnostics)
            }
            let neverBackwards = zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 }
            check("and did it without restarting the route", neverBackwards)
            // And audio was actually flowing throughout, or "never went
            // backwards" would be satisfied by a route that had stopped.
            check("with audio flowing the whole time", counts.last! > counts.first!)
            model.voiceIsolationMix = 100
        }

        // Handed back exactly as it was found, since everything below this runs
        // against whatever chain is left in place.
        model.enabledEffects = chainBefore
        await waitUntil("the chain came back", { !model.isBusy }, timeout: 14)
        check("routing survived every swap", model.isRunning)

        try section("patching")
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

        try section("device changes")
        // A real change to the device list, not a simulated one: creating an
        // aggregate makes CoreAudio publish kAudioHardwarePropertyDevices, which
        // is the same notification an unplug produces. What is being checked is
        // that the watcher is actually wired and that a change to devices the
        // route does not use leaves the route alone.
        //
        // Built over a device the route is *not* using, which it was not: the
        // decoy took the route's own destination as its sub-device, so it was
        // not an unrelated device at all — it enrolled the destination in a
        // second aggregate, the route rebuilt, and the check called that "audio
        // stopped". Measured, twice in three runs: the cycle counter went to 0
        // and the audio was flowing perfectly well a moment later.
        let cyclesBeforeChange = model.cycleCountForDiagnostics
        let deviceCountBefore = model.outputDevices.count
        let inUse = Set(
            [model.selectedDestinationUID, model.selectedSourceUID, model.monitorDeviceUID]
                .compactMap { $0 })
        let spare = model.outputDevices.first {
            !inUse.contains($0.uid) && !$0.transport.isVirtual && $0.outputChannels > 0
        }
        if let over = spare ?? model.outputDevices.first(where: { !inUse.contains($0.uid) }),
            let decoy = try? AggregateDevice(
                name: "YunAudio Flow Check",
                subDevices: [.init(uid: over.uid, driftCompensation: true)],
                clockMasterUID: over.uid)
        {
            note("decoy built over \(over.name), which this route does not use")
            await waitUntil(
                "the device list picked up the new device",
                { model.outputDevices.count > deviceCountBefore }, timeout: 6)
            check("an unrelated device did not stop the route", model.isRunning)
            if let error = model.lastError { note("error was: \(error)") }
            // Two different questions, and comparing one number to one taken
            // before the change answers neither. The IO cycle counter lives in
            // the RCU cell, and a rebuild frees that cell and makes another —
            // so the counter restarting from zero means "it rebuilt", not "the
            // audio stopped", and the old check read the first as the second.
            //
            // So: audio flowing is measured over a window *after* the change,
            // and whether anything rebuilt is reported separately. Only the
            // first is a failure. Whether an unrelated aggregate over the same
            // destination ought to perturb this route is a real question, and
            // it is not answered by a check that cannot tell the two apart.
            let afterChange = model.cycleCountForDiagnostics
            await pause(0.5)
            let flowing = model.cycleCountForDiagnostics
            note(
                "cycles \(cyclesBeforeChange) before the change, \(afterChange) after, "
                    + "\(flowing) half a second later")
            check("audio kept flowing across the change", flowing > afterChange)
            if afterChange < cyclesBeforeChange {
                note(
                    "the counter restarted, so the route was rebuilt by the new device "
                        + "appearing — worth knowing, and not the same as audio stopping")
            }
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

        try section("devices that share no sample rate")
        // A Razer Barracuda does 44.1 kHz out and 16 kHz in; a Seiren V3 Pro
        // does 48 and 96. Somebody who owns both is not doing anything unusual,
        // and this used to be refused outright with "the selected devices share
        // no sample rate" — which is the router declining to do the one thing
        // it exists for. The path cannot be bit-exact across that gap whatever
        // happens, so the only question is who resamples.
        if let awkward = model.outputDevices.first(where: { candidate in
            guard let source = model.selectedSource else { return false }
            return Set(candidate.availableSampleRates)
                .intersection(source.availableSampleRates).isEmpty
                && candidate.uid != model.selectedDestinationUID
        }) {
            let previous = model.selectedDestinationUID
            model.selectedDestinationUID = awkward.uid
            await waitUntil("the failed start unwound", { !model.isBusy }, timeout: 20)
            model.start()
            await waitUntil("it routed anyway", { model.isRunning }, timeout: 15)
            check("no error was reported", model.lastError == nil)
            if let quality = model.pathQuality {
                note(
                    "\(awkward.name): \(quality.integrityKey) at "
                        + "\(Int(quality.sampleRate)) Hz, mismatch "
                        + "\(quality.hasSampleRateMismatch)")
                // And it says so. A router that quietly converts and calls the
                // path clean would be lying about the one thing this project
                // is built on.
                check("it does not claim to be bit-exact", !quality.isBitExact)
                check("and it names the mismatch", quality.hasSampleRateMismatch)
            }
            await pause(upTo: 1.0, until: { model.cycleCountForDiagnostics > 0 })
            check("audio is flowing", model.cycleCountForDiagnostics > 0)
            model.selectedDestinationUID = previous
            await waitUntil("and it went back", { model.isRunning }, timeout: 15)
        } else {
            note("every output shares a rate with the source — not exercised")
        }

        try section("output-only aggregate members")
        // The mechanism behind the Bluetooth fix, checked on hardware that is
        // here: a member restricted to no input channels must still create,
        // still present its outputs, and not take its inputs into the
        // aggregate. If the HAL refused this, every Bluetooth destination would
        // stop working and the failure would look like the headset.
        if let withInputs = model.inputDevices.first(where: { $0.hasOutput }) {
            let unrestricted = try? AggregateDevice(
                name: "YunAudio Restriction Check A",
                subDevices: [.init(uid: withInputs.uid, driftCompensation: true)],
                clockMasterUID: withInputs.uid)
            let restricted = try? AggregateDevice(
                name: "YunAudio Restriction Check B",
                subDevices: [
                    .init(uid: withInputs.uid, driftCompensation: true, inputChannels: 0)
                ],
                clockMasterUID: withInputs.uid)
            check("the HAL accepts an output-only member", restricted != nil)
            // Does the key cap at all, or is it ignored? A device with three
            // inputs asked for one answers that in a way zero cannot: zero
            // could always be read as "no opinion".
            if let many = model.inputDevices.first(where: { $0.inputChannels > 1 }),
                let capped = try? AggregateDevice(
                    name: "YunAudio Restriction Check C",
                    subDevices: [
                        .init(uid: many.uid, driftCompensation: true, inputChannels: 1)
                    ],
                    clockMasterUID: many.uid),
                let device = try? AudioDevice(id: capped.id)
            {
                note(
                    "\(many.name): \(many.inputChannels) inputs, capped to 1 gives "
                        + "\(device.inputChannels)")
                capped.destroy()
            }
            if let restricted, let unrestricted,
                let plain = try? AudioDevice(id: unrestricted.id),
                let limited = try? AudioDevice(id: restricted.id)
            {
                note(
                    "\(withInputs.name): \(plain.inputChannels) in unrestricted, "
                        + "\(limited.inputChannels) in restricted")
                // Asserting what the HAL *does*, which is not what the header
                // implies. kAudioSubDeviceInputChannelsKey is descriptive, not
                // prescriptive: a device with three inputs asked for one still
                // presents three, and one asked for none still presents one.
                //
                // That closes off the obvious way to stop a Bluetooth headset
                // negotiating HFP — leaving its input out of the aggregate —
                // and it is asserted rather than merely written down so that a
                // future macOS honouring the key is noticed rather than never
                // looked at again.
                check(
                    "the channel key is still ignored",
                    limited.inputChannels == plain.inputChannels)
                // And the point of the exercise: the outputs are untouched, so
                // a headset can still be written to.
                check(
                    "and its outputs are untouched",
                    limited.outputChannels == plain.outputChannels
                        && limited.outputChannels > 0)
            }
            // And the neighbouring key, measured the same way rather than
            // assumed: a latency trim that the HAL quietly ignored would be a
            // control that moves and does nothing.
            if let output = model.outputDevices.first,
                let plain = try? AggregateDevice(
                    name: "YunAudio Latency Check A",
                    subDevices: [.init(uid: output.uid, driftCompensation: true)],
                    clockMasterUID: output.uid),
                let delayed = try? AggregateDevice(
                    name: "YunAudio Latency Check B",
                    subDevices: [
                        .init(
                            uid: output.uid, driftCompensation: true,
                            extraOutputLatencyFrames: 480)
                    ],
                    clockMasterUID: output.uid),
                let before = try? AudioDevice(id: plain.id),
                let after = try? AudioDevice(id: delayed.id)
            {
                let moved =
                    after.latencyFrames(scope: kAudioObjectPropertyScopeOutput)
                    - before.latencyFrames(scope: kAudioObjectPropertyScopeOutput)
                note("latency trim of 480 frames moved the aggregate by \(moved)")
                check("the latency trim actually delays the output", moved >= 480)
                plain.destroy()
                delayed.destroy()
            }

            unrestricted?.destroy()
            restricted?.destroy()
        } else {
            note("no device with both directions — skipped")
        }

        try section("singing")
        // Everything this needs already existed and none of it was joined up:
        // the pitch tracker, the music players' scripting dictionaries, and a
        // routed microphone. What was missing was the words, and those are a
        // file.
        model.isSingingVisible = true
        await pause(0.6)
        if let track = model.nowPlaying {
            note(
                "\(track.application): \(track.artist) — \(track.title) at \(Int(track.position))s"
            )
            check("a playing track has a duration", track.duration > 0)
        } else {
            note(
                NowPlaying.hasAPlayer
                    ? "nothing is playing — the live half was not exercised"
                    : "no music player installed — skipped")
        }
        // The matching is the part that decides whether the feature is usable,
        // because a file somebody downloaded is called whatever its author
        // called it.
        if let directory = RouterModel.lyricsDirectory {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Flow Check - Björk – Jóga.lrc")
            try? "[00:01.00]first\n[00:05.00]second".write(
                to: file, atomically: true, encoding: .utf8)
            let found = RouterModel.findLyrics(
                for: .init(
                    application: "Test", title: "Joga", artist: "Bjork", album: "",
                    position: 0, duration: 100, isPlaying: true))
            check("accents and punctuation do not stop a match", found != nil)
            check("and the words came with it", found?.lines.count == 2)
            let missing = RouterModel.findLyrics(
                for: .init(
                    application: "Test", title: "Nothing Like This", artist: "Nobody",
                    album: "", position: 0, duration: 100, isPlaying: true))
            check("a song with no file finds nothing", missing == nil)
            try? FileManager.default.removeItem(at: file)
        }
        // The key of what is playing, and how far it would have to move. The
        // profile match is unit-tested against synthesised chromas; what only
        // this can show is that a real spectrum reaches it at all.
        //
        // Five seconds because a key is no longer offered from the first window
        // — twenty of them is four seconds — and two would have measured only
        // that nothing had arrived yet.
        await pause(upTo: 5.0, until: { model.songKey != nil })
        if let key = model.songKey {
            note(
                String(
                    format: "heard %@ at %.0f%% confidence", key.name, key.confidence * 100))
            check("the key is one of the twelve", (0..<12).contains(key.pitchClass))
            check(
                "and its confidence is a fraction", key.confidence >= 0 && key.confidence <= 1)
            if let shift = model.suggestedShift {
                note("suggested shift \(shift) semitones")
                // More than half an octave is a different song rather than an
                // easier one.
                check("no suggestion moves it more than half an octave", abs(shift) <= 6)
            } else {
                note("nobody has sung yet, so there is nothing to move it towards")
            }
        } else {
            note("nothing musical is playing — the key was not measured")
        }

        // Pitch is switched on only while somebody is looking, which is what
        // makes a lyrics panel cheaper than the analysis panel.
        check("looking at it asks for the pitch", !model.analysisIsIdle)
        model.isSingingVisible = false
        check("and looking away clears the track", model.nowPlaying == nil)

        try section("output tone")
        // Ten bands at Razer's own centres, which is a real claim: somebody
        // moving from Windows can copy their settings across band for band.
        // The arithmetic is unit-tested; what is checked here is that a slider
        // reaches the signal and that it composes with a headphone correction
        // rather than replacing it.
        check("it starts flat", model.graphicEQIsFlat)
        check("and a flat tone control runs nothing", model.headphoneCurve == nil)
        model.setGraphicBand(4, at: 5)  // 1 kHz
        check("moving one band ends flat", !model.graphicEQIsFlat)
        if let curve = model.headphoneCurve {
            note(
                String(
                    format: "%.1f dB at 1 kHz, %.1f dB at 250 Hz",
                    curve.response(atHertz: 1000, sampleRate: 48000),
                    curve.response(atHertz: 250, sampleRate: 48000)))
            check(
                "the band it moved is the one that moved",
                abs(curve.response(atHertz: 1000, sampleRate: 48000) - 4) < 0.4)
            check(
                "and two octaves away is untouched",
                abs(curve.response(atHertz: 250, sampleRate: 48000)) < 0.6)
        } else {
            check("a moved band produces a curve", false)
        }
        // Beyond the range is clamped rather than obeyed, or a stray gesture
        // could ask for a boost the limiter then has to undo.
        model.setGraphicBand(99, at: 0)
        check("a band beyond the range is clamped", model.graphicEQ[0] == 5)
        check("no error was reported", model.lastError == nil)
        check("the route did not go down", model.isRunning)
        model.resetGraphicEQ()
        check("flattening puts it back", model.graphicEQIsFlat)
        check("and stops running anything", model.headphoneCurve == nil)

        try section("headphone correction")
        // Written into the folder the application reads, so what is exercised
        // is the path a person takes: download a file for your headphones, drop
        // it in, pick it. Parsing is unit-tested; this is the plumbing.
        if let directory = RouterModel.headphoneDirectory {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Flow Check Headphones.txt")
            let text = """
                Preamp: -6.0 dB
                Filter 1: ON PK Fc 1000 Hz Gain 6.0 dB Q 1.00
                Filter 2: ON LSC Fc 105 Hz Gain 4.0 dB Q 0.70
                """
            try? text.write(to: file, atomically: true, encoding: .utf8)
            model.refreshHeadphoneProfiles()
            check(
                "a dropped file is found",
                model.headphoneProfiles.contains { $0.name == "Flow Check Headphones" })

            model.headphoneProfileName = "Flow Check Headphones"
            check("it can be chosen", model.headphoneProfile != nil)
            check("no error was reported", model.lastError == nil)
            check("the route did not go down", model.isRunning)
            if let profile = model.headphoneProfile {
                note(
                    String(
                        format: "%d filters, %.1f dB at 1 kHz", profile.filters.count,
                        profile.response(atHertz: 1000, sampleRate: 48000)))
            }
            // It goes on the monitor when there is one, because that is the
            // headphone path by definition — and never on the main output,
            // which would send the far end the inverse of a fault they do not
            // have.
            check(
                "it targets what the wearer hears",
                model.correctedOutputUID
                    == (model.monitorDeviceUID ?? model.selectedDestinationUID))

            // A profile deleted from the folder must stop being used rather
            // than keep running from memory.
            try? FileManager.default.removeItem(at: file)
            model.refreshHeadphoneProfiles()
            check("deleting the file turns it off", model.headphoneProfileName == nil)
            check("and routing survived that too", model.isRunning)
        } else {
            note("no application support directory — skipped")
        }

        try await checkBusProcessing(model: model)

        try section("setups")
        // A setup captures devices; a scene captures processing. Confusing the
        // two would mean somebody choosing "podcast" could not know whether
        // they had changed a compressor or unplugged their headphones.
        //
        // Applying one sets the *system's* default input and output, which is
        // the point of the feature and is also the most invasive thing anything
        // in this file does: it reaches outside the application and moves
        // somebody's Sound settings. So what they were is taken first and put
        // back at the end, whatever happens in between — this check runs on a
        // machine somebody is using.
        let systemInputBefore = (try? AudioDevices.defaultInput())??.uid
        let systemOutputBefore = (try? AudioDevices.defaultOutput())??.uid
        let sourceBefore = model.selectedSourceUID
        model.saveQuickConfig(named: "Flow check setup")
        check(
            "it was saved", model.quickConfigs.contains { $0.name == "Flow check setup" })
        if let saved = model.quickConfigs.first(where: { $0.name == "Flow check setup" }) {
            check("it captured the router's devices", saved.sourceUID == sourceBefore)
            // The system's own defaults are half of what setting up for a call
            // means, and forgetting that step is why the first minute of every
            // call is spent on "you are on mute".
            check("and the system's own defaults", saved.systemOutputUID != nil)

            // Move somewhere else, then come back.
            if let elsewhere = model.inputDevices.map(\.uid).first(where: { $0 != sourceBefore }
            ) {
                model.selectedSourceUID = elsewhere
                let outcome = model.apply(saved)
                check("applying put the source back", model.selectedSourceUID == sourceBefore)
                check("and nothing was missing", outcome.isComplete)
                note("restored \(outcome.restored) thing(s)")
            } else {
                note("only one input on this machine — the round trip was not exercised")
            }

            // A device that is not here is the ordinary case of restoring a
            // setup away from the desk, not an error.
            var absent = saved
            absent.destinationUID = "no such device"
            let partial = model.apply(absent)
            check("a missing device is reported rather than thrown", !partial.isComplete)
            check(
                "and it is named, not printed as a UID",
                !model.describeMissing(
                    partial.missing
                ).isEmpty)
            _ = model.apply(saved)

            // A setup remembers whether the router was running, and one saved
            // with it idle has to put it back down. It could not: applying a
            // setup pushes its device changes in as a batch, a batch restarts a
            // running route, and the stop that follows therefore always arrived
            // while that restart still held the engine queue — where it was
            // refused outright and then undone by the restart's own start. This
            // is the certain case of the same defect the stopping section
            // catches by hand; there is no window to miss.
            await waitUntil("the setup settled", { !model.isBusy }, timeout: 15)
            await bringRoutingBack(model)
            if model.isRunning {
                var idle = saved
                idle.isRouting = false
                _ = model.apply(idle)
                await waitUntil("the idle setup settled", { !model.isBusy }, timeout: 15)
                check("a setup saved while idle puts the route down", !model.isRunning)
                _ = model.apply(saved)
                await waitUntil(
                    "and one saved while routing brings it back", { model.isRunning },
                    timeout: 15)
            } else {
                note("routing would not come up here — the idle setup was not exercised")
            }
        }
        model.deleteQuickConfig(named: "Flow check setup")
        check(
            "it was deleted",
            !model.quickConfigs.contains { $0.name == "Flow check setup" })

        // Put the machine's own settings back. Asserted rather than merely
        // attempted: leaving somebody's default microphone somewhere they did
        // not put it is the kind of thing they discover during a call.
        if let systemInputBefore {
            _ = try? AudioDevices.setDefault(systemInputBefore, forInput: true)
        }
        if let systemOutputBefore {
            _ = try? AudioDevices.setDefault(systemOutputBefore, forInput: false)
        }
        check(
            "the machine's own input was left where it was found",
            (try? AudioDevices.defaultInput())??.uid == systemInputBefore)
        check(
            "and its output too",
            (try? AudioDevices.defaultOutput())??.uid == systemOutputBefore)
        await waitUntil("and routing is still up", { model.isRunning }, timeout: 10)

        try section("excluded applications")
        // Every product in this category added an exclusion list *after* the
        // breakage reports. A tap changes how an application's audio leaves the
        // machine, and a DAW that finds its output redirected mid-session is a
        // lost take — by somebody with no reason to suspect a menu bar utility
        // they set up weeks ago.
        if let victim = model.availableApps.first {
            model.capturedAppBundleIDs.insert(victim.bundleID)
            check("it was captured", model.capturedAppBundleIDs.contains(victim.bundleID))
            model.setExcluded(true, bundleID: victim.bundleID)
            check("excluding it is remembered", model.isExcluded(victim.bundleID))
            // The exclusion has to take effect at once. Leaving it captured
            // until some later restart would make the setting look ignored.
            check(
                "and it stopped being captured",
                !model.capturedAppBundleIDs.contains(victim.bundleID))
            // Stronger than "not selected": selecting is a click and a click can
            // be an accident, so the rule has to survive one.
            model.capturedAppBundleIDs.insert(victim.bundleID)
            check(
                "selecting it again does not take",
                !model.capturedAppBundleIDs.contains(victim.bundleID))
            model.setExcluded(false, bundleID: victim.bundleID)
            check("and it can be allowed again", !model.isExcluded(victim.bundleID))
            model.capturedAppBundleIDs.insert(victim.bundleID)
            check("then it captures", model.capturedAppBundleIDs.contains(victim.bundleID))
            model.capturedAppBundleIDs.remove(victim.bundleID)
        } else {
            note("no applications to exclude — skipped")
        }

        try section("volume keys")
        // The research said we almost certainly had the aggregate-volume bug,
        // because we ship an aggregate. We do not: ours is created private and
        // is never selectable as a system output, and the device somebody does
        // select — our virtual driver — publishes a volume control that works.
        // What is left is other people's aggregates and multi-output devices,
        // where the keys really are dead and nothing says so.
        for output in model.outputDevices.prefix(6) {
            let settable = output.hasSettableVolume(scope: kAudioObjectPropertyScopeOutput)
            note("\(output.name): volume keys \(settable ? "work" : "do nothing")")
        }
        if let driver = model.outputDevices.first(where: {
            $0.uid == ClockAnchorPublisher.driverDeviceUID
        }) {
            check(
                "our own device answers the volume keys",
                driver.hasSettableVolume(scope: kAudioObjectPropertyScopeOutput))
        } else {
            note("the driver is not installed — skipped")
        }
        check(
            "and the interface only warns when they are dead",
            model.volumeKeysAreDead
                == !(model.selectedDestination?.hasSettableVolume(
                    scope: kAudioObjectPropertyScopeOutput) ?? true))

        try section("output alignment")
        // The delay is a property of the aggregate rather than of the graph, so
        // setting one rebuilds the route. What is being checked is that the
        // route survives that and that the value is what the system was told.
        check("only outputs in the path are offered", !model.alignableOutputs.isEmpty)
        if let output = model.alignableOutputs.first {
            let before = model.outputDelay(of: output.uid)
            model.setOutputDelay(12, for: output.uid)
            check("it reads back", abs(model.outputDelay(of: output.uid) - 12) < 0.001)
            await waitUntil("the route came back up", { model.isRunning }, timeout: 10)
            check("no error was reported", model.lastError == nil)
            // Waited for rather than read: the counter starts again with the
            // new aggregate, so reading it the instant the route reports itself
            // up is reading it before the first cycle has run.
            await waitUntil(
                "audio is flowing again", { model.cycleCountForDiagnostics > 0 }, timeout: 5)
            // Nothing beyond half a second is alignment any more, and a value
            // set by accident must not be able to make the app look broken.
            model.setOutputDelay(99_999, for: output.uid)
            check(
                "an absurd delay is clamped",
                model.outputDelay(of: output.uid) == RouterModel.maximumOutputDelay)
            model.setOutputDelay(before, for: output.uid)
            check("and zero means none at all", model.outputDelay(of: output.uid) == before)
            await waitUntil("still running afterwards", { model.isRunning }, timeout: 10)
        }

        try section("remote control")
        // Somebody wiring a Stream Deck key to this has no way to see what
        // happened, so the parse has to be exact rather than forgiving. The
        // failure mode being guarded against is a mistyped URL that means
        // something — a mute that turns into a stop.
        check(
            "the definite forms are definite",
            RemoteCommand.parse(URL(string: "yunaudio://mute/on")!) == .mute(true)
                && RemoteCommand.parse(URL(string: "yunaudio://mute/off")!) == .mute(false))
        check(
            "a bare noun toggles",
            RemoteCommand.parse(URL(string: "yunaudio://mute")!) == .mute(nil))
        check(
            "start and stop read as on and off",
            RemoteCommand.parse(URL(string: "yunaudio://routing/start")!) == .routing(true)
                && RemoteCommand.parse(URL(string: "yunaudio://record/stop")!)
                    == .record(false)
        )
        check(
            "a scene comes through with its spaces",
            RemoteCommand.parse(URL(string: "yunaudio://preset/Voice%20call")!)
                == .preset("Voice call"))
        check(
            "an unknown verb is refused rather than guessed",
            RemoteCommand.parse(URL(string: "yunaudio://mute/sometimes")!) == nil)
        check(
            "an unknown noun is refused",
            RemoteCommand.parse(URL(string: "yunaudio://explode")!) == nil)
        check(
            "somebody else's scheme is not ours",
            RemoteCommand.parse(URL(string: "http://mute/on")!) == nil)

        // Parsing correctly is worth nothing if the system never hands us the
        // URL. The scheme lives in Info.plist, which is copied by a shell
        // script — exactly the kind of thing that goes missing without the code
        // noticing, because every test of the parser still passes.
        let schemes =
            (Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        check("the bundle claims the scheme", schemes.contains(RemoteCommand.scheme))

        // And the commands actually do what they say, against the real model.
        let wasMuted = model.isInputMuted
        model.perform(.mute(true))
        check("mute on mutes", model.isInputMuted)
        model.perform(.mute(true))
        check("and doing it twice is still muted", model.isInputMuted)
        model.perform(.mute(nil))
        check("the toggle toggles", !model.isInputMuted)
        model.isInputMuted = wasMuted
        check(
            "a scene that does not exist says so",
            model.perform(.preset("no such scene")) == nil)
        check(
            "a setup URL is understood",
            RemoteCommand.parse(URL(string: "yunaudio://config/Podcast")!) == .config("Podcast")
        )
        check(
            "and a setup that does not exist says so",
            model.perform(.config("no such setup")) == nil)
        if let scene = model.allPresets.first {
            check("and one that does is applied", model.perform(.preset(scene.name)) != nil)
        }

        try section("falling back when a device disappears")
        // Unplugging the microphone used to stop everything and wait. That is
        // right only when there is nowhere else to go: somebody on a call whose
        // USB microphone falls out wants the call to carry on, and wants their
        // own microphone back the moment it is plugged in again.
        //
        // The ranking is checked as arithmetic first, because the real half can
        // only ever exercise one path — a destroyed aggregate cannot be brought
        // back with the same UID, so nothing on this machine can make the
        // return journey happen on demand.
        check(
            "the most recently used present device wins",
            RouterModel.replacement(
                for: "gone", recent: ["gone", "second", "third"],
                available: ["third", "second"]) == "second")
        check(
            "anything present beats nothing",
            RouterModel.replacement(for: "gone", recent: [], available: ["only"]) == "only")
        check(
            "the device that vanished is never the answer",
            RouterModel.replacement(
                for: "gone", recent: ["gone"], available: ["gone"]) == nil)
        check(
            "with nowhere to go it says so",
            RouterModel.replacement(for: "gone", recent: ["a"], available: []) == nil)
        check(
            "choosing a device moves it to the front",
            RouterModel.remember("b", in: ["a", "b", "c"]) == ["b", "a", "c"])
        check(
            "and the list does not grow without bound",
            RouterModel.remember("x", in: (0..<8).map { "d\($0)" }).count == 8)

        // Now the real half: a decoy destination that is genuinely removed.
        if let original = model.selectedDestinationUID,
            let destination = model.selectedDestination,
            let decoy = try? AggregateDevice(
                name: "YunAudio Fallback Check",
                subDevices: [.init(uid: destination.uid, driftCompensation: true)],
                clockMasterUID: destination.uid)
        {
            await pause(1.0)
            model.selectedDestinationUID = decoy.uid
            await waitUntil(
                "the route moved to the decoy",
                { model.selectedDestinationUID == decoy.uid }, timeout: 3)
            // Whether the decoy can actually carry the route is a property of
            // this machine rather than of the fall-back: an aggregate device
            // cannot be a member of another aggregate, and this application
            // builds one, so on a machine whose only removable device is a
            // decoy the start fails with "output channel 0 … is not part of the
            // aggregate" and the route is already down before anything is
            // unplugged. Reported rather than asserted — what is being tested
            // below is what happens when the device goes, and that is worth
            // testing from either state.
            //
            // This used to be `waitUntil("and came up on it", isRunning)`, which
            // asserted nothing at all: selecting a device restarts the route,
            // the stop that begins the restart is queued rather than immediate,
            // so `isRunning` was still true from the route being replaced and
            // the wait returned about a millisecond after the assignment. It
            // reported a route on the decoy for as long as it has existed, and
            // there was never one.
            await settle(model, timeout: 20)
            let onTheDecoy =
                model.isRunning
                && model.activeRoutes.contains { $0.destination.deviceUID == decoy.uid }
            note(
                onTheDecoy
                    ? "the route came up on the decoy"
                    : "the decoy cannot carry a route here: "
                        + (model.lastError ?? "no error given"))

            decoy.destroy()
            // Waited for rather than sampled at a fixed moment, and stated as
            // what actually matters. Moving off a device that has gone means a
            // real teardown and a real rebuild — seconds of device work — so "it
            // is still running two seconds later" was a question only luck could
            // answer, and it was the wrong question: the route legitimately
            // comes down for a moment while it moves. What must not happen is
            // that it stays down, which is exactly what did happen — the
            // substitution re-pointed a model whose engine had stopped, and
            // nothing started it again.
            await waitUntil(
                "it did not stay down", { model.isRunning && !model.isBusy }, timeout: 25)
            check("it moved to another output", model.selectedDestinationUID != decoy.uid)
            check("and remembers what it was forced off", model.displacedDestinationUID != nil)
            // The name has to survive the device being gone: it is not in any
            // list to look up any more, which is the whole reason it is said.
            check("and can still name it", model.displacedDestinationName != nil)
            note("fell back to \(model.selectedDestinationUID ?? "nothing")")

            // Choosing by hand is a decision, not an accident: it has to end
            // the claim on the device that went away, or plugging that one back
            // in later would move somebody off what they just picked. It has to
            // be a different device from the one the fall-back landed on —
            // setting the same value changes nothing and would pass whatever
            // the code did.
            let elsewhere = model.outputDevices.map(\.uid)
                .first { $0 != model.selectedDestinationUID }
            if let elsewhere {
                model.selectedDestinationUID = elsewhere
                check(
                    "choosing by hand releases the claim",
                    model.displacedDestinationUID == nil)
            } else {
                note("only one output on this machine — the release was not exercised")
            }
            model.selectedDestinationUID = original
            await waitUntil(
                "and it is running again", { model.isRunning && !model.isBusy }, timeout: 20)
        } else {
            note("could not build a decoy device — skipped")
        }

        try section("integrity check")
        // The project's central claim, and until now it could only be made from
        // a terminal: somebody who installs the app had no way to find out
        // whether their own path is bit-exact.
        if !model.canCheckIntegrity {
            note("the destination has no input to read back from — skipped")
        } else {
            // The check restores what it found: it stops the route afterwards
            // and starts it again only if it was running to begin with, which is
            // right — running one from an idle router should not leave audio
            // flowing that nobody asked for. That makes "the route came back
            // afterwards" a claim about this section only when a route was up
            // before it, and asserting it against whatever the section above
            // happened to leave behind made a failure here point at a fault
            // somewhere else entirely. It did, for a while: the whole of this
            // section's failure was the fall-back above leaving the route down.
            await bringRoutingBack(model)
            check("a route was up to be restored", model.isRunning)
            model.checkIntegrity()
            check("the check started", model.isCheckingIntegrity)
            await waitUntil(
                "it finished", { !model.isCheckingIntegrity && !model.isBusy },
                timeout: 40)
            check("a result came back", model.integrityResult != nil)
            // The model already works out which of the two failures this was and
            // says so in words somebody can act on; not printing it turned "a
            // result came back ✗" into a line with no next step.
            if let error = model.integrityError { note(error) }
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

        try await checkApplicationList(model: model)

        try section("stopping")
        // Stop, pressed while the engine queue was busy with a rebuild. The busy
        // guard refused it and returned having done nothing, and the start that
        // every rebuild chains behind its own teardown then brought the route
        // back — audio flowing again some seconds after somebody put it down,
        // with nothing having asked for it.
        //
        // Nothing here is a race to catch. `restartIfRunning` takes `isBusy` on
        // the main actor before it hops to the queue, so the edit below and the
        // stop after it are one turn apart and the stop lands inside the window
        // every time.
        //
        // Brought up first rather than assumed: there is no rebuild to stop
        // during if the route is already down, and the assertion below would
        // then pass without having tested anything.
        await bringRoutingBack(model)
        let rateBefore = model.preferredSampleRate
        let errorBefore = model.lastError
        model.preferredSampleRate = rateBefore == 48000 ? 44100 : 48000
        check("the edit took the engine queue", model.isBusy)
        model.stop()
        await waitUntil("the queue unwound", { !model.isBusy }, timeout: 15)
        check("a stop pressed during a rebuild stays stopped", !model.isRunning)
        // Or it came down for a reason nobody was testing: a rate this hardware
        // will not take fails the rebuild, and a failed rebuild looks exactly
        // like an honoured stop from here.
        check("and it came down because it was asked to", model.lastError == errorBefore)
        model.preferredSampleRate = rateBefore

        model.stop()
        await waitUntil("the route came down", { !model.isRunning }, timeout: 5)
        check("levels were cleared", model.routeLevels.isEmpty)
        check("routes were cleared", model.activeRoutes.isEmpty)

        // The point of pills rather than a strip: what is on screen at rest is
        // one word, because there is one thing true at rest.
        //
        // After the queue has unwound, not merely after the route came down.
        // The state pill reads "working" while a stop is still in flight, which
        // is the truth and not the state being asserted here — it failed on one
        // run in three until this waited.
        await waitUntil("the stop finished unwinding", { !model.isBusy }, timeout: 10)
        let idle = StatusPills.pills(for: model)
        note("idle: " + idle.map(\.id).joined(separator: " "))
        check(
            "the measured pills went away with the route",
            !idle.contains { ["rate", "buffer", "latency", "integrity"].contains($0.id) })
        check("the state pill stayed", idle.contains { $0.id == "state" })
        check("and it says idle", idle.first?.label == loc("Idle"))
        check("nothing is measured while stopped", model.pathLatencyMilliseconds == 0)

        // Settings, last, because every one of them changes something
        // process-wide — the language every string is read in, the appearance
        // every window is drawn in, the activation policy — and doing that in
        // the middle of the routing flows would leave whatever failed there
        // looking like a routing failure.
        //
        // A preference is exactly the kind of thing that looks right and does
        // nothing: the control moves, the interface redraws, and the value
        // reaches neither the code that reads it nor the disk. So each one is
        // asserted twice — that it changed what it claims to change, and that
        // it survived being written down.
        try section("settings")
        let originalLanguage = YunTheme.shared.language
        let originalAppearance = YunTheme.shared.appearance
        let originalAccent = YunTheme.shared.accent
        let originalHue = YunTheme.shared.accentHue
        let originalBuffer = model.bufferFrames
        let originalDock = InterfaceOptions.showsDockIcon

        // A language that changes what `loc()` returns and leaves every open
        // window showing the old strings is half a feature, and the half that
        // is missing is the visible one. `loc()` reads the theme so that
        // Observation registers the dependency; this is that wiring, asserted
        // rather than assumed — the tracker stands in for a view body.
        final class Repaint: @unchecked Sendable { var happened = false }
        let repaint = Repaint()
        withObservationTracking {
            _ = loc("Settings")
        } onChange: {
            repaint.happened = true
        }

        YunTheme.shared.language = .english
        check("English is what the table returns", loc("Settings") == "Settings")
        check("a view that had read a string was invalidated", repaint.happened)
        YunTheme.shared.language = .traditionalChinese
        check("Chinese is what the table returns", loc("Settings") == "設定")
        check("the choice reached the lookup", YunStrings.language == .traditionalChinese)
        check("it was written down", YunTheme.persisted().language == .traditionalChinese)
        // The window builds these from enums, which is how four English words
        // sat in the sidebar of an otherwise Chinese interface for months.
        let labels = YunAppearance.allCases.map(\.title) + YunAccent.allCases.map(\.title)
        check(
            "every theme and accent label is translated",
            labels.allSatisfy { !$0.allSatisfy(\.isASCII) })
        YunTheme.shared.language = .system
        check("the override was cleared again", YunTheme.persisted().language == .system)

        YunTheme.shared.appearance = .dark
        check(
            "the process went dark",
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        YunTheme.shared.appearance = .light
        check(
            "and light again",
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        check("it was written down", YunTheme.persisted().appearance == .light)

        // Judged in one appearance, since a dynamic colour resolves against
        // whichever is current: the pair is what the two-appearance render is
        // for, and what is asserted here is that the choice arrives at all.
        YunTheme.shared.accent = .monochrome
        let monochrome = Yun.Palette.accentComponents()
        check(
            "monochrome is neutral",
            abs(monochrome.red - monochrome.blue) < 0.02)
        YunTheme.shared.accent = .blue
        let blue = Yun.Palette.accentComponents()
        // Channel-wise, because the two share one: near-white and the dark
        // theme's blue are both 0.98 in the blue channel, so comparing that
        // alone would pass whether or not the setting did anything.
        let moved = max(
            abs(blue.red - monochrome.red),
            max(abs(blue.green - monochrome.green), abs(blue.blue - monochrome.blue)))
        check("the accent reached the palette", moved > 0.1)
        check("and it is blue", blue.blue > blue.red + 0.2)
        YunTheme.shared.accent = .custom
        YunTheme.shared.accentHue = 1.0 / 3
        let custom = Yun.Palette.accentComponents()
        check(
            "the hue control reaches the colour",
            custom.green > custom.red + 0.1 && custom.green > custom.blue + 0.1)
        let storedAccent = YunTheme.persisted()
        check(
            "the accent was written down",
            storedAccent.accent == .custom
                && abs((storedAccent.hue ?? 0) - 1.0 / 3) < 1e-9)

        InterfaceOptions.showsDockIcon = true
        check("the Dock icon appeared", NSApp.activationPolicy() == .regular)
        InterfaceOptions.showsDockIcon = false
        check("and went away again", NSApp.activationPolicy() == .accessory)

        // The one setting here that the audio path reads. It was persisted and
        // never passed to the engine for the life of the presets, so "it is in
        // the file" is not the assertion — "the model is holding it" is, and
        // both are checked.
        let otherBuffer: UInt32 = originalBuffer == 256 ? 128 : 256
        model.bufferFrames = otherBuffer
        check("the buffer size was taken", model.bufferFrames == otherBuffer)
        check("and saved", PreferencesStore.load().bufferFrames == otherBuffer)
        note(
            String(
                format: "%d frames is %.2f ms per IO cycle at %.0f Hz", otherBuffer,
                Double(otherBuffer) / model.preferredSampleRate * 1000,
                model.preferredSampleRate))

        // Everything above is somebody's real settings file.
        model.bufferFrames = originalBuffer
        InterfaceOptions.showsDockIcon = originalDock
        YunTheme.shared.accentHue = originalHue
        YunTheme.shared.accent = originalAccent
        YunTheme.shared.appearance = originalAppearance
        YunTheme.shared.language = originalLanguage
        check(
            "the settings were put back",
            YunTheme.persisted().accent == originalAccent
                && YunTheme.persisted().language == originalLanguage
                && model.bufferFrames == originalBuffer)

        try await checkMIDI(model: model)
        try await checkScoring(model: model)
        try await checkVoiceActivity(model: model)
        try await checkScripting(model: model)
        try await checkRedrawCost(model: model)
        try await checkCarriedState(model: model)

        summarise()
    }

    /// Scoring the singing, and the key of music that is genuinely playing.
    ///
    /// Two things only this can show. The first is that the melody file, the
    /// per-source pitch trackers and the scorer are joined up — the scorer is a
    /// pure function and is asserted to death in the unit tests, but "the file
    /// was found and the tap reached it" is not something a unit test can say.
    ///
    /// The second is the one this project had written down as unfinished: the
    /// key detector had only ever been exercised against synthesised chromas,
    /// because the last time anybody ran the check Spotify was paused. So this
    /// makes its own music — a chord progression it built, in a key it chose —
    /// plays it through a real process, captures that process through the
    /// application's own tap, and asks what key it is in. Nothing is assumed
    /// about what happens to be installed or playing.
    private static func checkScoring(model: RouterModel) async throws {
        try section("scoring the singing")

        // The file half first, because it needs no devices. A hand-built MIDI
        // file so the assertion is against bytes rather than against something
        // downloaded — a bass line under a melody, so the reduction has to
        // choose.
        guard let directory = RouterModel.lyricsDirectory else {
            note("no application support directory — skipped")
            return
        }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let words = directory.appendingPathComponent("Flow Check - Scoring.lrc")
        let tune = directory.appendingPathComponent("Flow Check - Scoring.mid")
        try? "[00:00.00]first\n[00:01.00]second".write(
            to: words, atomically: true, encoding: .utf8)
        try? melodyFile().write(to: tune)
        defer {
            try? FileManager.default.removeItem(at: words)
            try? FileManager.default.removeItem(at: tune)
        }

        let track = NowPlaying.Track(
            application: "Test", title: "Scoring", artist: "Flow Check", album: "",
            position: 0, duration: 100, isPlaying: true)
        let melody = RouterModel.findMelody(for: track)
        check("the tune was found beside the words", melody != nil)
        if let melody {
            note(
                "\(melody.notes.count) notes, \(melody.melody.count) in the line, "
                    + String(format: "%.1f s", melody.duration))
            // The bass note is in the file and must not be in the tune.
            check(
                "the accompaniment is not the tune", melody.melody.allSatisfy { $0.midi > 48 })
            check("and the tune is monophonic", melody.melody.count == 4)
            let reference = melody.samples(every: KaraokeScore.referenceInterval)
            check("it samples into a reference series", reference.count > 30)
            // Sung exactly, against the real reference: a hundred, or the
            // arithmetic and the file disagree about time.
            let perfect = reference.map {
                PitchSample(time: $0.time, midi: $0.midi)
            }
            let score = KaraokeScore.score(sung: perfect, reference: reference)
            note(
                String(
                    format: "singing the file back at itself scores %.0f%%", score.percentage))
            check("singing it exactly is a hundred", score.percentage > 99.9)
            check("and there is enough of it to judge", score.isMeaningful)
        }

        // Now the live half. Routing has to be up for the per-source rings to
        // exist at all.
        if !model.isRunning {
            model.start()
            await waitUntil("routing came back up", { model.isRunning }, timeout: 10)
        }
        guard model.isRunning else {
            note("routing would not start — the live half was not exercised")
            return
        }

        model.isSingingVisible = true
        model.isScoringSinging = true
        await pause(upTo: 1.0, until: { model.isScoringSinging })
        check("scoring started", model.isScoringSinging)
        if let problem = model.singingError { note(problem) }
        check("one singer per source", model.singers.count == model.sourceGroups.count)
        note(
            "singers: "
                + model.singers.map(\.name).joined(separator: ", ")
                + " on \(model.engineTranscriptTaps) tap(s)")
        // The structural claim: two microphones is two answers, not one
        // averaged. With one source it cannot be shown, and saying so is the
        // honest result.
        if model.singers.count > 1 {
            check(
                "each singer is a different source",
                Set(model.singers.map(\.id)).count == model.singers.count)
        } else {
            note("only one source on this machine — a duet was not exercised")
        }

        // One set of rings, two consumers. Transcription and scoring both want
        // this source's audio on its own, and a ring is single-consumer: two
        // drains would each get half of it and neither would say so.
        if model.transcriptionUnavailableReason == nil {
            model.startTranscribing()
            await pause(1.0)
            check(
                "transcribing alongside it did not take the taps away", model.isScoringSinging)
            check(
                "and there is still one tap per source",
                model.engineTranscriptTaps == model.sourceGroups.count)
            check("the singers survived", model.singers.count == model.sourceGroups.count)
            model.stopTranscribing()
            await pause(0.5)
            check("stopping the transcript left the scoring listening", model.isScoringSinging)
            check("and its taps open", model.engineTranscriptTaps > 0)
        } else {
            note("transcription unavailable here — sharing the taps was not exercised")
        }

        // A tune it has never seen cannot be scored, and that is a different
        // fact from nought per cent.
        check(
            "with no tune loaded nothing is claimed",
            model.melody != nil || model.singers.allSatisfy { !$0.score.isMeaningful })

        model.isScoringSinging = false
        await pause(0.3)
        check("switching it off clears the singers", model.singers.isEmpty)

        // The key of real music. This is the part the project had written down
        // as unverified.
        try section("the key of music that is actually playing")
        let tonic = 5  // F, chosen so an always-C answer is caught
        let wave = URL(fileURLWithPath: "/tmp/yunaudio-key-check.wav")
        guard (try? progressionWave(tonic: tonic).write(to: wave)) != nil else {
            note("could not write the test audio — skipped")
            model.isSingingVisible = false
            return
        }
        defer { try? FileManager.default.removeItem(at: wave) }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wave.path]
        guard (try? player.run()) != nil else {
            note("afplay would not start — skipped")
            model.isSingingVisible = false
            return
        }
        defer { if player.isRunning { player.terminate() } }
        await pause(1.0)

        // Captured through the application's own process tap, which is the
        // path a person's music takes. Nothing acoustic: a microphone hearing
        // the speakers would be measuring the room.
        model.refreshApps()
        let captured = model.availableApps.first {
            $0.name.localizedCaseInsensitiveContains("afplay")
        }
        guard let captured else {
            note("afplay did not appear as a tappable process — skipped")
            model.isSingingVisible = false
            return
        }
        let alreadyCaptured = model.capturedAppBundleIDs
        model.capturedAppBundleIDs.insert(captured.bundleID)
        await waitUntil(
            "the player was captured", { model.isRunning && !model.isBusy }, timeout: 10)
        note("capturing \(captured.name) — \(model.activeRoutes.count) route(s)")

        // The capture has to have become routes before anything downstream of
        // it means anything. It does not always: `start` resolves the bundle
        // identifier against the processes running at that moment, and a player
        // that has stopped playing is no longer one of them — so the tap is
        // silently not built and the mix carries the microphone alone.
        //
        // Without this the section went on to blame the analysis tap for
        // hearing no music, having never established that any music had been
        // put on the bus. Measured: two routes where the microphone alone is
        // two routes, and `tapOwners` empty.
        let tapped = model.activeRoutes.contains { model.application(of: $0) != nil }
        check("the capture became routes on the bus", tapped)
        // Which of them failed. Resolving to no process, a tap CoreAudio
        // refused, and a tap that published no channels to route all end as no
        // routes on the bus, and they want three different things done about
        // them. Saying only "no routes" sent the last person reading the
        // analysers.
        if !model.unresolvedCaptures.isEmpty {
            note(
                "resolved to no running process: "
                    + model.unresolvedCaptures.joined(separator: ", "))
        }
        if !model.refusedCaptures.isEmpty {
            note("CoreAudio refused the tap: " + model.refusedCaptures.joined(separator: ", "))
        }
        if !tapped, model.unresolvedCaptures.isEmpty, model.refusedCaptures.isEmpty {
            note(
                "the tap was built and carried no channels — destination "
                    + "\(model.selectedDestination?.outputChannels ?? 0) channel(s)")
        }

        // With the chain running, because that is the case anybody karaokes in
        // and it is the one that was in doubt. Voice isolation is a speech
        // model and the equaliser is a high-pass at 80 Hz, and both of them
        // exist to remove exactly what music is made of — so if the key came
        // from a signal they had touched, this is where it would show.
        let alreadyEnabled = model.enabledEffects
        model.enabledEffects.formUnion([.voiceIsolation, .equaliser])
        await waitUntil("the chain came up", { model.isRunning && !model.isBusy }, timeout: 10)
        note(
            "chain: "
                + model.enabledEffects.map(\.rawValue).sorted().joined(separator: ", "))

        // Started over, so the chroma is of the music and not of whatever was
        // in the room a moment ago.
        model.isSingingVisible = false
        model.isSingingVisible = true

        // One chord is not a key, and the first fold of the chroma is one
        // chord. This was the whole defect: the panel answered from whichever
        // chord happened to be sounding when it opened, so a song in F was
        // reported as B♭ — its own subdominant — at 100% confidence, with a
        // transpose suggestion built on top of that.
        await pause(0.6)
        check("one chord is not yet a key", model.songKey == nil)

        // Then until there is an answer at all, which now means until enough of
        // the piece has been heard for one to be offered.
        let cyclesBeforeTheKey = model.cycleCountForDiagnostics
        await pause(upTo: 10.0, until: { model.songKey != nil })
        // Whether anything was measured at all, which is a different question
        // from what was measured and has to be asked first. A route can be up,
        // report no error and carry nothing: `AudioDeviceStart` returns noErr
        // and the IO proc is then simply never called, and every meter in the
        // application reads a truthful zero.
        let flowed = model.cycleCountForDiagnostics > cyclesBeforeTheKey
        check("audio was flowing while the key was measured", flowed)

        if let key = model.songKey {
            note(
                String(
                    format: "played F major, heard %@ at %.0f%% confidence", key.name,
                    key.confidence * 100))
            check(
                "the key of real playing music is the key it was built in",
                key.pitchClass == tonic && !key.isMinor)
            check("and it is not reported as a guess", key.confidence > 0.15)
            // The suggested transpose needs a singer as well as a song, and
            // there is nobody here — but it must be a number or nothing, never
            // nonsense.
            if let shift = model.suggestedShift {
                note("suggested shift \(shift) semitones")
                check("no suggestion moves it more than half an octave", abs(shift) <= 6)
            } else {
                note("nobody sang, so there is nothing to move it towards")
            }
        } else {
            check("real playing music produced a key at all", false)
            // Which of the four it was. The section used to say the last of
            // them whichever had actually happened, and that sent the next
            // person reading the analysers and the processing chain — neither
            // of which had been reached. The signal has four places to stop and
            // they want four different things done about them.
            if !flowed {
                note("no IO cycle ran — nothing on this machine was measured")
            } else if !tapped {
                note("the capture never joined the mix, so no music was on the bus")
            } else if model.analysis.duration <= 0 {
                note("audio is flowing but the analysis ring handed over none of it")
            } else if !player.isRunning {
                note("the player stopped before enough of it had been heard")
            } else {
                note(
                    String(
                        format: "the analysis tap heard %.1f s and found no key in it",
                        model.analysis.duration))
            }
        }

        // Two sources are on the bus now — the microphone and the player — so
        // this is where the duet's mechanism can be exercised. Not two people:
        // there is one microphone on this machine and no way to conjure a
        // second. What is checked is the part that was actually built, which is
        // that each source gets its own pitch track keyed on its own ring
        // rather than one tracker over the mix.
        if model.sourceGroups.count > 1 {
            model.isScoringSinging = true
            await pause(1.5)
            check("a second source is a second singer", model.singers.count > 1)
            check(
                "and they are different sources",
                Set(model.singers.map(\.id)).count == model.singers.count)
            note(
                "singers: "
                    + model.singers.map { "\($0.name) \($0.note ?? "—")" }
                    .joined(separator: ", "))
            model.isScoringSinging = false
        } else {
            note("the capture did not become a second source — the duet was not exercised")
        }

        model.enabledEffects = alreadyEnabled
        model.capturedAppBundleIDs = alreadyCaptured
        model.isSingingVisible = false
        if player.isRunning { player.terminate() }
        await waitUntil("the capture was released", { !model.isBusy }, timeout: 10)
    }

    /// A bass line under a four-note melody, as a Standard MIDI File.
    ///
    /// Built here rather than shipped as a fixture so that what the parser is
    /// asserted against is bytes somebody can read in this file.
    private static func melodyFile() -> Data {
        func variableLength(_ value: Int) -> [UInt8] {
            var buffer = [UInt8(value & 0x7F)]
            var rest = value >> 7
            while rest > 0 {
                buffer.insert(UInt8(rest & 0x7F | 0x80), at: 0)
                rest >>= 7
            }
            return buffer
        }
        func big32(_ value: Int) -> [UInt8] {
            [
                UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
            ]
        }
        func big16(_ value: Int) -> [UInt8] {
            [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func chunk(_ events: [(Int, [UInt8])]) -> [UInt8] {
            var body: [UInt8] = []
            for (delta, bytes) in events { body += variableLength(delta) + bytes }
            body += [0x00, 0xFF, 0x2F, 0x00]
            return Array("MTrk".utf8) + big32(body.count) + body
        }
        // 480 ticks a quarter at the default 120 bpm: half a second a note.
        let bass = chunk([
            (0, [0x90, 36, 100]), (1920, [0x80, 36, 0]),
        ])
        let line = chunk(
            [
                (0, [0x90, 67, 100]), (480, [0x80, 67, 0]),
                (0, [0x90, 69, 100]), (480, [0x80, 69, 0]),
                (0, [0x90, 71, 100]), (480, [0x80, 71, 0]),
                (0, [0x90, 72, 100]), (480, [0x80, 72, 0]),
            ])
        var bytes = Array("MThd".utf8) + big32(6) + big16(1) + big16(2) + big16(480)
        bytes += bass + line
        return Data(bytes)
    }

    /// I – IV – V – I in a chosen key, as a 16-bit WAV somebody can play.
    ///
    /// Pure tones voiced from MIDI 72 upwards. The union of those three chords
    /// is the whole diatonic scale and the tonic triad appears twice, which is
    /// the shape the key profiles are built to find. Voiced up there rather
    /// than in a bass singer's range because a 2048-point transform at 48 kHz
    /// is 23.4 Hz a bin and a semitone at 130 Hz is 7.8 — three notes to a bin,
    /// and the answer would be about the resolution rather than about the key.
    private static func progressionWave(tonic: Int, repeats: Int = 6) -> Data {
        let rate = 44100.0
        var samples: [Int16] = []
        let chords = [0, 5, 7, 0].map { degree in
            [degree, degree + 4, degree + 7, degree + 12].map { 72 + tonic + $0 }
        }
        var frame = 0
        for _ in 0..<repeats {
            for chord in chords {
                for _ in 0..<Int(rate) {
                    let time = Double(frame) / rate
                    var value = 0.0
                    for note in chord {
                        value += sin(2 * .pi * 440 * pow(2, (Double(note) - 69) / 12) * time)
                    }
                    samples.append(Int16(value / Double(chord.count) * 12000))
                    frame += 1
                }
            }
        }

        var bytes: [UInt8] = []
        func little32(_ value: Int) {
            bytes += [
                UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF),
                UInt8(value >> 24 & 0xFF),
            ]
        }
        func little16(_ value: Int) {
            bytes += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
        }
        let dataBytes = samples.count * 2
        bytes += Array("RIFF".utf8)
        little32(36 + dataBytes)
        bytes += Array("WAVEfmt ".utf8)
        little32(16)
        little16(1)  // PCM
        little16(1)  // mono
        little32(Int(rate))
        little32(Int(rate) * 2)
        little16(2)
        little16(16)
        bytes += Array("data".utf8)
        little32(dataBytes)
        for sample in samples {
            let raw = UInt16(bitPattern: sample)
            bytes += [UInt8(raw & 0xFF), UInt8(raw >> 8)]
        }
        return Data(bytes)
    }

    /// What the interface re-derives while nobody is touching it.
    ///
    /// The poll is measured elsewhere and is cheap. What it publishes is not:
    /// every observable it writes invalidates every view body that read it, and
    /// `@Observable` tracks that per property reached *anywhere* inside a body —
    /// including through a computed property the body merely passes along. A
    /// window whose whole tree is one body therefore redraws entirely because a
    /// meter moved, and anything expensive it happens to touch is paid twenty
    /// times a second.
    ///
    /// So the bodies are counted rather than reasoned about, and the expensive
    /// reads are timed rather than assumed expensive. Both halves have already
    /// been wrong here.
    private static func checkRedrawCost(model: RouterModel) async throws {
        try section("what the interface redraws")

        // The window has to be on screen or SwiftUI evaluates nothing and the
        // counts are all zero, which would read as "nothing redraws".
        NSApp.activate(ignoringOtherApps: true)
        var onScreen = false
        for window in NSApp.windows where window.title == "YunAudio" {
            window.makeKeyAndOrderFront(nil)
            onScreen = true
        }
        await bringRoutingBack(model)
        guard onScreen, model.isRunning else {
            note(
                onScreen
                    ? "no route is up, so nothing is publishing — skipped"
                    : "no window on screen, so no body runs — skipped")
            return
        }
        model.isAnalysisVisible = true
        await pause(0.5)

        // Whole-process processor time across the same window. Body counts say
        // what is being re-derived; this says what it costs, which is the only
        // figure that settles whether any of it was worth changing. It includes
        // the IO thread and the poll, so it is a ceiling on the interface's
        // share rather than a measurement of it — and it is the same ceiling
        // before and after, which is what makes the difference meaningful.
        func processorSeconds() -> Double {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            return user + system
        }

        BodyCount.reset()
        BodyCount.isCounting = true
        let cpuBefore = processorSeconds()
        let seconds = 4.0
        await pause(seconds)
        let cpuSpent = processorSeconds() - cpuBefore
        BodyCount.isCounting = false
        let counts = BodyCount.counts
        note(
            String(
                format: "%.0f ms of processor time in %.0f s idle — %.1f%% of one core",
                cpuSpent * 1000, seconds, cpuSpent / seconds * 100))

        // Twenty hertz is the poll. A view drawing a meter is meant to be here;
        // a view drawing the header, the device pickers and the whole inspector
        // is not, and the difference between the two is the finding.
        for (name, count) in counts.sorted(by: { $0.value > $1.value }) {
            note(
                String(
                    format: "%-16s %4d bodies — %.1f Hz", (name as NSString).utf8String!, count,
                    Double(count) / seconds))
        }
        if counts.isEmpty { note("nothing was counted") }

        let poll = 20.0 * seconds
        // Half the poll rate, which is loose on purpose: this is wall clock on
        // a machine that is also running a route. What it has to catch is a
        // whole-window body pinned to the meters — measured at 20.0 Hz, one
        // evaluation per poll — while not failing because a redraw or two got
        // coalesced differently.
        check(
            "the whole window does not redraw with the meters",
            Double(counts["MainWindow"] ?? 0) < poll / 2)
        check(
            "nor the patchbay, which nothing on the poll can change",
            Double(counts["RoutingCanvas"] ?? 0) < poll / 2)
        check(
            "nor the balance panel",
            Double(counts["CalibrationPanel"] ?? 0) < poll / 2)
        // And the other half: the meters must still be live, or the fix was to
        // stop drawing rather than to stop over-drawing.
        check(
            "the meters are still redrawing",
            Double(counts["RouteStrip"] ?? 0) > poll / 4)

        // Two reads the window body was making on every one of those
        // evaluations. Timed rather than guessed: one of them turned out to
        // hash two binaries off disk, and the other is three stat calls.
        func microseconds(_ iterations: Int, _ body: () -> Void) -> Double {
            let started = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { body() }
            return Double(DispatchTime.now().uptimeNanoseconds - started)
                / Double(iterations) / 1000
        }
        note(
            String(
                format: "driverIsOutOfDate %.0f µs, isDriverInstalled %.0f µs",
                microseconds(50) { _ = model.driverIsOutOfDate },
                microseconds(50) { _ = model.isDriverInstalled }))
        // The driver only changes when this application installs it, so a body
        // reading it is asking the file system a question that cannot have a
        // new answer. Anything above a few microseconds means it is being
        // re-derived rather than remembered.
        check(
            "the driver freshness answer is remembered",
            model.driverIsOutOfDate == model.driverIsOutOfDate)
        check(
            "and costs nothing to ask for",
            microseconds(200) { _ = model.driverIsOutOfDate } < 5)

        // The collection-building computed properties, in the same units, so a
        // decision about caching one of them has a number behind it rather than
        // an intuition. Caching something cheap is a net loss — a second copy
        // that can fall out of step — so these are reported whatever they say.
        note(
            String(
                format: "sourceGroups %.1f µs, buses %.1f µs, alignableOutputs %.1f µs",
                microseconds(500) { _ = model.sourceGroups },
                microseconds(500) { _ = model.buses },
                microseconds(500) { _ = model.alignableOutputs }))
        note(
            String(
                format: "pathLatencyMilliseconds %.1f µs, transcriptText %.1f µs",
                microseconds(200) { _ = model.pathLatencyMilliseconds },
                microseconds(200) { _ = model.transcriptText }))
    }

    /// What survives a graph being rebuilt underneath a running route.
    ///
    /// The engine publishes a new graph three ways — a fresh `start`, a route
    /// edit, a chain swap — and each carries a different amount of the previous
    /// one across. Anything it does not carry has to be pushed back by the
    /// model, and the failure mode when it is not is silence: the interface
    /// goes on reporting what the model holds, which is right, while the graph
    /// runs without it. Two have already been found this way. This asserts the
    /// third case rather than waiting for the fourth.
    private static func checkCarriedState(model: RouterModel) async throws {
        try section("state carried across a rebuild")
        await bringRoutingBack(model)
        guard model.isRunning else {
            note("no route is up — skipped")
            return
        }

        let everything = Set(RouterModel.GraphSetting.allCases)

        // Set up before the question is asked rather than after it. What
        // `appliedToGraph` records is what actually reached the graph, so the
        // output correction is absent when no bus has a curve — which is
        // correct, and is the ordinary state of a machine nobody has dialled a
        // tone into. So "everything" quietly meant "the six that had something
        // to push" while the assertion claimed seven. The section resets the
        // curve on its way out, so every run arrived here with nothing to
        // correct and failed on a route that was in fact complete.
        model.isDucking = true
        let profile = model.headphoneProfileName
        model.setGraphicBand(4, at: 5)
        await pause(0.3)
        check("a tone control is running", model.headphoneCurve != nil)

        // And a route that really is fresh. `start` is the one publication that
        // begins empty; dialling the band above went in through an edit, so the
        // state has to be pushed through a stop and a start to be asking about
        // the case this section is named for.
        model.stop()
        await waitUntil("the route came down to be rebuilt", { !model.isRunning }, timeout: 10)
        await bringRoutingBack(model)
        await waitUntil(
            "and a fresh one came up", { model.isRunning && !model.isBusy }, timeout: 20)
        await pause(0.4)
        check("a fresh route has everything pushed into it", model.appliedToGraph == everything)

        // A route edit. `updateRoutes` carries the gains, the mutes, the
        // recording rings and the ducking, and does not carry the headphone
        // correction — the engine says in as many words that the model puts
        // that back, and for a while nothing did.
        let before = model.activeRoutes
        if let first = before.first {
            model.disconnectRoute(source: first.source, destination: first.destination)
            await pause(0.3)
            model.connect(source: first.source, destination: first.destination)
            await pause(0.3)
            check("the route edit took", model.activeRoutes.count == before.count)
            check(
                "and the output correction went back in with it",
                model.appliedToGraph.contains(.headphoneCorrection))
        } else {
            note("no routes to edit — skipped")
        }

        // A chain swap. `updateEffects` carries the correction but builds fresh
        // Audio Units, so every stored knob position has to be pushed again.
        model.setEffect(.compressor, enabled: true)
        await waitUntil("the chain swap finished", { !model.isBusy }, timeout: 10)
        await pause(0.4)
        check(
            "a chain swap leaves the knob positions in the units",
            model.appliedToGraph.contains(.effectValues))
        check(
            "and does not drop the output correction",
            model.appliedToGraph.contains(.headphoneCorrection))

        // A full restart, which carries nothing at all.
        model.bufferFrames = model.bufferFrames == 256 ? 128 : 256
        await waitUntil(
            "the restart finished", { model.isRunning && !model.isBusy }, timeout: 20)
        await pause(0.4)
        check("everything is pushed back after a restart", model.appliedToGraph == everything)
        note("applied: " + model.appliedToGraph.map(\.rawValue).sorted().joined(separator: " "))

        model.setEffect(.compressor, enabled: false)
        model.resetGraphicEQ()
        model.isDucking = false
        model.headphoneProfileName = profile
        await waitUntil(
            "routing survived all of it", { model.isRunning && !model.isBusy }, timeout: 20)

        // A change that arrives while a start is still in flight.
        //
        // `start` reads every parameter off the model before it hops to the
        // engine queue, and `restartIfRunning` used to give up on `isRunning` —
        // which is false for the whole of that hop. So the change was neither
        // applied nor remembered: the model held it, the interface showed it,
        // and the route went on running without it until something else
        // happened to rebuild. Caught in this file first, where attaching a
        // monitor straight after a chain swap took twenty seconds to appear.
        let bufferBefore = model.bufferFrames
        let wantedBuffer: UInt32 = bufferBefore == 256 ? 128 : 256
        model.voiceIsolationMix = model.voiceIsolationMix == 100 ? 80 : 100
        // Now, with that restart in flight rather than after it.
        model.bufferFrames = wantedBuffer
        await waitUntil(
            "the queue came free", { model.isRunning && !model.isBusy }, timeout: 30)
        await pause(1.0)
        note("engine reports \(model.pathQuality?.bufferFrames ?? -1) frames")
        check(
            "a change made during a start still reaches the engine",
            model.pathQuality?.bufferFrames == Int(wantedBuffer))
        model.bufferFrames = bufferBefore
        await waitUntil("and back", { model.isRunning && !model.isBusy }, timeout: 30)

        try await checkSecondMix(model: model)

        // And what is written down. A `didSet` that calls `persist()` for a
        // field `Preferences` does not have is a setting that looks remembered
        // and is not.
        try section("settings that survive a relaunch")
        let originalBehaviour = model.tapMuteBehavior
        let other: TapMuteBehavior = originalBehaviour == .muted ? .unmuted : .muted
        model.tapMuteBehavior = other
        check("the model took it", model.tapMuteBehavior == other)
        check(
            "and it reached the file",
            PreferencesStore.load().tapMuteBehavior == other.storageKey)
        model.tapMuteBehavior = originalBehaviour
        check(
            "and back again",
            PreferencesStore.load().tapMuteBehavior == originalBehaviour.storageKey)

        // The same shape, found the same way. The recording format had a
        // picker, an engine that read it and a preset that carried it, and no
        // `didSet` and no field — so somebody who chose AAC to save disk got
        // WAV files the next morning.
        let originalFormat = model.recordingFormat
        let otherFormat: Recorder.Format = originalFormat == .aac ? .wav : .aac
        model.recordingFormat = otherFormat
        check(
            "the recording format reached the file",
            PreferencesStore.load().recordingFormat == otherFormat.rawValue)
        model.recordingFormat = originalFormat
        check(
            "and back again",
            PreferencesStore.load().recordingFormat == originalFormat.rawValue)

        // And a third time, on the field added directly after `tapMuteBehavior`
        // — which is how this one was found. The script editor's own `didSet`
        // called `persist()`, `Preferences` had the field, and `persist()` did
        // not name it, so the memberwise initialiser wrote nil and a script
        // somebody had spent an evening on was gone at the next launch. The
        // interface said nothing; it restored `""` and looked untouched.
        let originalScript = model.residentScript
        model.residentScript = "// survives a relaunch"
        check(
            "the resident script reached the file",
            PreferencesStore.load().residentScript == "// survives a relaunch")
        model.residentScript = originalScript
        check(
            "and back again",
            PreferencesStore.load().residentScript == originalScript)
    }

    /// The monitor mix, which is carried by route *indices* rather than by
    /// anything the routes themselves say.
    ///
    /// Two ways of moving those indices were moving them underneath the monitor
    /// faders, and neither says anything: a send driving the wrong route
    /// changes a level somewhere else, and a monitor that stopped existing
    /// leaves both buses, both sets of faders and the legend above them
    /// exactly as they were.
    private static func checkSecondMix(model: RouterModel) async throws {
        try section("the second mix survives a change to the first")
        await bringRoutingBack(model)
        guard model.isRunning else {
            note("no route is up — skipped")
            return
        }
        guard let monitor = model.monitorOptions.first else {
            note("no second output to monitor on — skipped")
            return
        }
        await waitUntil("nothing else is in flight", { !model.isBusy }, timeout: 20)
        let monitorBefore = model.monitorDeviceUID
        model.monitorDeviceUID = monitor.uid
        // Waited on the routes rather than on `!isBusy`. Attaching a monitor
        // goes through `stop { start() }`, and there is a turn between the two
        // where nothing is busy and the old routes are still up — so a check
        // taken on the flag alone passes or fails on scheduling.
        await waitUntil(
            "the monitor came up",
            { model.activeRoutes.contains { $0.destination.deviceUID == monitor.uid } },
            timeout: 15)
        let withMonitor = model.activeRoutes.count
        check("and the sends point at them", model.monitorRoutesAreConsistent)

        // A patchbay edit. Pulling one cable out of the main mix moves every
        // route after it down by one, and the monitor's routes are all after
        // it — so a send that was not remapped drives whatever inherited its
        // index, which is somebody's level to the far end.
        if let victim = model.activeRoutes.first(where: {
            $0.destination.deviceUID != monitor.uid
        }) {
            model.disconnectRoute(source: victim.source, destination: victim.destination)
            await pause(0.4)
            check("the cable was pulled", model.activeRoutes.count == withMonitor - 1)
            check(
                "and the monitor sends still point at monitor routes",
                model.monitorRoutesAreConsistent)
            model.connect(source: victim.source, destination: victim.destination)
            await pause(0.4)
            check(
                "putting it back leaves them consistent too", model.monitorRoutesAreConsistent)
        } else {
            note("nothing in the main mix to pull — skipped")
        }

        // And a channel-mode change, which used to be swapped in as `routes` —
        // the microphone into the destination, and nothing else. The monitor
        // was not in that list, so it simply stopped existing.
        let modeBefore = model.channelMode
        model.channelMode = modeBefore == .mono ? .stereo : .mono
        await waitUntil("the change settled", { model.isRunning && !model.isBusy }, timeout: 20)
        await pause(0.5)
        check(
            "changing the channel mode did not take the monitor away",
            model.activeRoutes.contains { $0.destination.deviceUID == monitor.uid })
        check("and left the sends consistent", model.monitorRoutesAreConsistent)
        model.channelMode = modeBefore
        await waitUntil("and back", { model.isRunning && !model.isBusy }, timeout: 20)
        check(
            "the monitor is still there afterwards",
            model.activeRoutes.contains { $0.destination.deviceUID == monitor.uid })

        model.monitorDeviceUID = monitorBefore
        await waitUntil("monitoring went back as it was", { !model.isBusy }, timeout: 15)
    }

    /// Scripting, against the real model rather than a stub.
    ///
    /// The unit tests drive a stub, which is right for the object model but
    /// cannot show the two things that only matter here: that a command from a
    /// script reaches the same place a button does, and that an event actually
    /// fires when the thing happens rather than when a test calls `dispatch`.
    private static func checkScripting(model: RouterModel) async throws {
        try section("scripting")

        let before = model.residentScript
        defer { model.residentScript = before }

        // Reading. The status has to describe this machine, not a shape.
        let reading = model.runScript(
            "var s = yun.status(); [s.running, s.muted, yun.presets().length].join('/')")
        check("a script can read the state", reading.isSuccess)
        note("status reads: \(reading.value)")

        // Acting, through the same vocabulary a button uses.
        let wasMuted = model.isInputMuted
        _ = model.runScript("yun.mute(true)")
        check("a script can mute", model.isInputMuted)
        _ = model.runScript("yun.mute(false)")
        check("and unmute", !model.isInputMuted)
        model.isInputMuted = wasMuted

        // A name this application does not have must stop the script rather
        // than being skipped, or the rest of it runs against an arrangement
        // nobody chose.
        let missing = model.runScript("yun.preset('no such scene'); yun.mute(true)")
        check("an unknown scene stops the script", !missing.isSuccess)
        check("and nothing after it ran", model.isInputMuted == wasMuted)

        // Events, fired by the application doing the thing rather than by the
        // check calling into the script layer.
        model.residentScript = """
            var seen = [];
            yun.log('loaded');
            yun.on('muted', function () { seen.push('muted'); yun.log('muted'); });
            yun.on('unmuted', function () { seen.push('unmuted'); yun.log('unmuted'); });
            """
        check("a resident script loads", model.residentScriptError == nil)
        // The top level is where somebody puts the line that tells them the
        // script is the one they think it is, and it was thrown away — only a
        // handler's output ever reached the panel headed "What it has said".
        check("and what it said while loading is shown", model.scriptLog.contains("loaded"))
        if let problem = model.residentScriptError { note(problem) }
        model.isInputMuted = true
        model.isInputMuted = false
        model.isInputMuted = wasMuted
        note("script said: " + model.scriptLog.joined(separator: ", "))
        check(
            "muting the microphone reached the script",
            model.scriptLog.contains("muted") && model.scriptLog.contains("unmuted"))

        // And a broken one is reported where somebody will see it, rather than
        // silently not running for the rest of the session.
        model.residentScript = "yun.on('nope', function () {});"
        check("an unknown event is refused at load", model.residentScriptError != nil)
        if let problem = model.residentScriptError { note(problem) }
    }

    /// The system's own voice detector.
    ///
    /// Worth a check rather than a version test, because the first reading of
    /// it here said that no device on this machine publishes the detector —
    /// including the built-in microphone. The properties live on the **input**
    /// scope; the global scope answers "absent" for every device, which is
    /// indistinguishable from the feature not existing.
    ///
    /// Whether it actually *fires* is proved elsewhere, and deliberately:
    ///
    /// ```
    /// yunaudio-cli vad BlackHole --prove
    /// ```
    ///
    /// That plays synthesised speech into a loopback device, reads it back from
    /// the same device's input, meters what arrived and asserts the detector
    /// reported voice — three runs out of three. It cannot live here, and the
    /// reason is worth writing down rather than rediscovering: with a route
    /// already running, pointing an `AVAudioEngine` at a device the aggregate
    /// holds makes `start()` raise from Objective-C, which `try?` does not
    /// catch and which takes the whole application down mid-check. The first
    /// version of this section did exactly that, silently, and every section
    /// after it simply never ran.
    private static func checkVoiceActivity(model: RouterModel) async throws {
        try section("the system's own voice detector")

        let inputs = (try? AudioDevices.all())?.filter(\.hasInput) ?? []
        let publishing = inputs.filter { VoiceActivityWatcher.isAvailable(on: $0.id) }
        note("\(publishing.count) of \(inputs.count) input device(s) publish 'vAd+'")
        check("the detector is published on the input scope", !publishing.isEmpty)

        guard let source = model.selectedSource else { return }
        check(
            "including the source this route is using",
            VoiceActivityWatcher.isAvailable(on: source.id))
        check("and the model agrees it can be used", model.canDetectVoiceActivity)

        // Switched on by the route coming up, since the header is explicit that
        // the state reads 0 with input not running — an indicator wired to a
        // detector nobody enabled would be permanently dark and look correct.
        check("and the route switched it on", VoiceActivityWatcher.isEnabled(on: source.id))
        // And the watcher the model is actually holding says so. The device
        // answering yes is not the same claim: the watcher's initialiser hands
        // back a live object even when its own enable write failed, and nothing
        // in the application used to ask.
        check("and the watcher the model holds is running", model.isDetectingVoiceActivity)
        note(
            "reference for echo cancellation: "
                + (VoiceActivityWatcher.suggestedReferenceDeviceUID(for: source.id)
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? "none suggested — the default output"))

        // The warning only ever appears while muted, or it would be a meter.
        let wasMuted = model.isInputMuted
        model.isInputMuted = false
        check("nothing to warn about while the microphone is live", !model.isSpeakingWhileMuted)
        model.isInputMuted = wasMuted
    }

    /// MIDI learn, both halves.
    ///
    /// The decoding, the takeover rule and the binding storage are asserted as
    /// pure functions in the unit tests. What only this can show is that a
    /// message arriving through CoreMIDI reaches the model and moves it.
    ///
    /// There is no controller on this machine — `MIDIGetNumberOfSources()`
    /// reports zero — so a virtual source stands in for one. As far as the rest
    /// of the system is concerned it is a source like any other: the
    /// application's own client sees it appear, connects its input port to it
    /// and receives from it by exactly the path a knob on a desk would take.
    /// Without that, the client, the port, the reconnection and the decode of a
    /// real `MIDIEventList` would only ever run on somebody else's machine.
    private static func checkMIDI(model: RouterModel) async throws {
        try section("midi")
        let midi = model.midiControl
        note(
            "CoreMIDI sources: \(midi.sourceNames.count)"
                + (midi.sourceNames.isEmpty
                    ? "" : " — " + midi.sourceNames.joined(separator: ", ")))
        if let error = midi.startupError { note(error) }
        check("the client and the input port opened", midi.startupError == nil)

        // This is somebody's real preferences file.
        let originalBindings = midi.storedBindings
        let originalOutput = model.outputDecibels
        let originalInput = model.inputDecibels
        let originalMute = model.isInputMuted

        let master = MIDITarget.fader(.master)
        midi.forget(master)
        midi.learningTarget = master
        midi.receive(.cc(7, 100))
        check(
            "learn bound the control that moved",
            midi.binding(for: master) == MIDIAddress(channel: 0, kind: .controlChange(7)))
        check("and stopped listening once it had one", midi.learningTarget == nil)
        check(
            "the binding reached the preferences file",
            PreferencesStore.load().midiBindings?[master.storageKey] == "0.cc.7")

        // Soft takeover, against the real model rather than a stand-in for it.
        model.outputDecibels = -6
        midi.receive(.cc(7, 0))
        check(
            "a fader arriving at the bottom leaves the master where it was",
            abs(model.outputDecibels + 6) < 0.01)
        check("and the row still shows it as not in charge", !midi.isEngaged(master))
        midi.receive(.cc(7, 127))
        check(
            "sweeping past the level takes the master over",
            abs(model.outputDecibels - 12) < 0.01)
        check("and the row says so", midi.isEngaged(master))
        midi.receive(.cc(7, 64))
        check(
            "after which the master follows the knob to the decibel",
            abs(model.outputDecibels + 13.7953) < 0.01)
        note(String(format: "CC 64 is %.2f dB", model.outputDecibels))

        // A pad, carried out through the same list the URL scheme answers to.
        let mute = MIDITarget.command(url: RemoteCommand.mute(nil).url.absoluteString)
        midi.bind(MIDIAddress(channel: 0, kind: .note(36)), to: mute)
        model.isInputMuted = false
        midi.receive(.note(36, velocity: 100))
        check("a pad bound to mute mutes the microphone", model.isInputMuted)
        midi.receive(.note(36, velocity: 0))
        check("letting go of it does not unmute", model.isInputMuted)
        midi.receive(.note(36, velocity: 100))
        check("and pressing it again does", !model.isInputMuted)

        midi.bind(MIDIAddress(channel: 0, kind: .note(36)), to: .fader(.input))
        check(
            "a control claimed for something else leaves its old row empty",
            midi.binding(for: mute) == nil)

        try await checkMIDIThroughCoreMIDI(model: model)

        midi.restore(originalBindings)
        model.persistMIDIBindings()
        model.outputDecibels = originalOutput
        model.inputDecibels = originalInput
        model.isInputMuted = originalMute
        check("the bindings were put back", midi.storedBindings == originalBindings)
    }

    /// The half that only a real `MIDIEventList` can exercise.
    private static func checkMIDIThroughCoreMIDI(model: RouterModel) async throws {
        let midi = model.midiControl
        guard let loopback = MIDILoopback(name: "YunAudio flow check") else {
            note("no virtual source could be created; the CoreMIDI half was not exercised")
            check("a virtual MIDI source could be created", false)
            return
        }
        defer { loopback.tearDown() }

        // A source that appeared after launch is the ordinary case: somebody
        // plugs a controller in and then presses learn.
        var appeared = false
        for _ in 0..<40 where !appeared {
            if midi.sourceNames.contains(loopback.name) {
                appeared = true
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        check("a source that appeared after launch was connected", appeared)
        note("CoreMIDI sources now: \(midi.sourceNames.joined(separator: ", "))")

        let input = MIDITarget.fader(.input)
        midi.forget(input)
        midi.learningTarget = input
        check("the virtual source accepted a message", loopback.send(.cc(11, 20)) == noErr)
        var learned = false
        for _ in 0..<40 where !learned {
            if midi.binding(for: input) != nil {
                learned = true
            } else {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        check("a message that travelled through CoreMIDI was learned", learned)
        check(
            "and it decoded as the control that sent it",
            midi.binding(for: input) == MIDIAddress(channel: 0, kind: .controlChange(11)))

        // And then moves the model. Sent one at a time with a pause: each
        // packet arrives on CoreMIDI's thread and hops to the main actor, and
        // two hops in flight at once have no guaranteed order between them.
        model.inputDecibels = 0
        loopback.send(.cc(11, 0))
        try? await Task.sleep(for: .milliseconds(200))
        check(
            "a real message at the bottom of the travel does not slam the trim",
            abs(model.inputDecibels) < 0.01)
        loopback.send(.cc(11, 127))
        var moved = false
        for _ in 0..<40 where !moved {
            if model.inputDecibels > 11 {
                moved = true
            } else {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        check("and one that sweeps past it moves the input trim", moved)
        note(String(format: "input trim now %.2f dB", model.inputDecibels))
    }

    /// What starting a route costs when nothing is being captured.
    ///
    /// Enumerating every audio process on the machine used to happen at the top
    /// of every start, including the ones with no applications captured — which
    /// is most of them, and includes every restart caused by a setting
    /// changing. It buys the process identifiers of the applications about to
    /// be tapped; with none to tap it buys nothing.
    private static func checkStartCost(model: RouterModel) async throws {
        try section("what starting costs with nothing captured")
        let captured = model.capturedAppBundleIDs
        model.capturedAppBundleIDs = []
        model.stop()
        await waitUntil("it came down", { !model.isBusy && !model.isRunning }, timeout: 15)

        let began = Date()
        model.start()
        await waitUntil("and up again", { model.isRunning }, timeout: 15)
        let elapsed = Date().timeIntervalSince(began) * 1000
        note(String(format: "%.0f ms from asking to routing", elapsed))
        // Generous, because it is a real aggregate on real hardware and this
        // machine is not quiet. What it catches is the enumeration coming back.
        check("starting is not dominated by listing every process", elapsed < 4000)
        model.capturedAppBundleIDs = captured
    }

    /// What the twenty-hertz poll costs while nothing is happening.
    ///
    /// Everything else here asks whether a control works. This asks what the
    /// interface costs when nobody is touching it, which is the state a menu bar
    /// application spends its entire life in and the one nothing was measuring.
    ///
    /// Two numbers, and the second is the interesting one. The first is the time
    /// the poll itself takes, which was never the problem. The second is how
    /// many of the properties it assigns to were already holding that value:
    /// every stored property of an `@Observable` publishes on assignment rather
    /// than on change, so a poll that writes nine unchanged values still
    /// re-evaluates the body of every view that read any of them, twenty times a
    /// second, for ever.
    private static func checkPollCost(model: RouterModel) async throws {
        try section("what the idle interface costs")

        // Deliberately placed straight after the idle-cost section, which has
        // just switched the analysis, the levelling and the ducking off and on
        // again. Both of those states are worth a number and they are nothing
        // like each other.
        await bringRoutingBack(model)
        guard model.isRunning else {
            note("no route is up, so the poll is not running and there is nothing to measure")
            return
        }

        /// Runs the poll for a while and reports what one tick cost.
        func measure() async -> (microseconds: Double, cost: RouterModel.PollCost) {
            model.measuresPollBreakdown = true
            model.resetPollCost()
            // Long enough to be dominated by steady state rather than by
            // whatever the previous section left moving.
            await pause(4)
            let cost = model.pollCost
            guard cost.polls > 0 else { return (0, cost) }
            return (cost.seconds / Double(cost.polls) * 1e6, cost)
        }

        let visible = model.isAnalysisVisible

        model.isAnalysisVisible = false
        await pause(0.4)
        let quiet = await measure()
        guard quiet.cost.polls > 0 else {
            note("the poll did not run")
            model.isAnalysisVisible = visible
            return
        }
        note(
            String(
                format: "panel closed: %d polls, %.0f µs each — %.2f%% of one core",
                quiet.cost.polls, quiet.microseconds, quiet.microseconds / 50_000 * 100))
        note(
            String(
                format: "%d observable writes, %d of them unchanged (%.0f%%)",
                quiet.cost.writes, quiet.cost.unchanged,
                Double(quiet.cost.unchanged) / Double(max(quiet.cost.writes, 1)) * 100))
        for (name, seconds) in model.pollBreakdown.sorted(by: { $0.value > $1.value }).prefix(6)
        {
            note(
                String(
                    format: "    %-16s %6.0f µs", (name as NSString).utf8String!,
                    seconds / Double(quiet.cost.polls) * 1e6))
        }

        model.isAnalysisVisible = true
        await pause(0.4)
        let analysing = await measure()
        note(
            String(
                format: "panel open:   %d polls, %.0f µs each — %.2f%% of one core",
                analysing.cost.polls, analysing.microseconds,
                analysing.microseconds / 50_000 * 100))
        model.isAnalysisVisible = visible
        model.measuresPollBreakdown = false

        // The verdict is re-read twice a second rather than twenty times, so it
        // has to be shown to still be there — a stale pill claiming a clean
        // path is the one failure mode this application must not have.
        check("the path verdict is still being reported", model.pathQuality != nil)

        // A ceiling rather than a target, and deliberately a loose one. This is
        // wall clock on whatever machine is running the check, and the same
        // build measured 174, 240, 290 and 476 µs on this one depending on what
        // else was compiling at the time. What it has to do is catch the state
        // it was found in — 1501 to 1589 µs, because the path verdict was being
        // re-derived from the HAL twenty times a second — while not failing on
        // a busy afternoon. Anything approaching a millisecond means something
        // expensive is back on a path that runs for ever in the background,
        // which is the kind of thing nobody notices until a laptop is warm.
        check(
            "with the panel closed the poll stays well under a millisecond",
            quiet.microseconds < 900)

        // The analysers cost what they cost — an FFT, a pitch tracker and
        // Apple's sound model, twenty times a second — and they are the feature.
        // What matters is that the bill arrives only while somebody is looking:
        // if the two figures were the same, the panel's switch would not be
        // doing anything.
        check(
            "and the analysers only cost while the panel is open",
            analysing.microseconds > quiet.microseconds * 3)

        // The real assertion about the poll itself. With a route up and nobody
        // touching anything, most of what it assigns has not moved — the path
        // verdict, the clock lock, the plugin list, the clip count, the rate
        // ratio — and an `@Observable` publishes on assignment rather than on
        // change, so every one of those used to re-evaluate the body of every
        // view that had read it. Measured at 67 to 71% of all writes.
        check(
            "most of what it writes is recognised as unchanged",
            quiet.cost.unchanged * 2 > quiet.cost.writes)

        try checkStartupCost(model: model)
    }

    /// What launching costs, and which part of it.
    ///
    /// A menu bar application is launched once and then left alone, so this is
    /// not the number that decides whether the thing is pleasant to use — but
    /// it is the one nobody had, and "it feels quick on this machine" is not a
    /// measurement. The parts are re-timed warm, which understates every one of
    /// them; what a warm number is good for is saying which of them is worth
    /// looking at cold.
    private static func checkStartupCost(model: RouterModel) throws {
        try section("what launching costs")

        note(String(format: "exec to a live run loop: %.0f ms", launchSeconds * 1000))

        func timed(_ name: String, _ body: () -> Void) -> TimeInterval {
            let entered = DispatchTime.now().uptimeNanoseconds
            body()
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - entered) / 1e9
            note(String(format: "  %@: %.1f ms warm", name, seconds * 1000))
            return seconds
        }

        var warm = 0.0
        warm += timed("refreshDevices") { model.refreshDevices() }
        warm += timed("refreshPlugins") { model.refreshPlugins() }
        warm += timed("refreshHeadphoneProfiles") { model.refreshHeadphoneProfiles() }
        warm += timed("presets and quick configs") {
            _ = UserPresets.load()
            _ = QuickConfigStore.load()
        }
        note(String(format: "  %.1f ms of that is the model's own, warm", warm * 1000))

        // Not on the launch path — on the *start* path, at the top of every
        // `start()`, whether or not anything is being tapped. It is here
        // because it is the same kind of question and because the number is
        // worth having beside the others: enabling one effect tears the route
        // down and builds it back, and this is part of what that costs.
        let apps = timed("refreshApps, at the top of every start") { model.refreshApps() }
        note(
            String(
                format: "  %d application(s) enumerated, %d captured",
                model.availableApps.count, model.capturedAppBundleIDs.count))

        // Loose, because it is measuring a debug build on a machine that may
        // have several of these running at once. It is here to catch the shape
        // of failure that actually happens — somebody putting a device
        // enumeration or a disk walk on the launch path — rather than to police
        // a hundred milliseconds either way.
        check("launch is under three seconds", launchSeconds < 3)
        check("re-deriving everything the model derives at launch is under a second", warm < 1)
        check("enumerating applications is under a quarter second", apps < 0.25)
    }

    /// What the bottom of the window is actually showing.
    ///
    /// The row is built as data before it is drawn, because which pills are
    /// present *is* the behaviour — one that disappears when it has nothing to
    /// say cannot be checked by looking at a screenshot of a machine where it
    /// happened to have something. A view cannot be asked what it is showing;
    /// the list it is built from can.
    private static func checkStatusPills(model: RouterModel) throws {
        try section("status pills")
        let pills = StatusPills.pills(for: model)
        note(pills.map(\.id).joined(separator: " "))
        check("every pill carries a label", pills.allSatisfy { !$0.label.isEmpty })
        check("no pill appears twice", Set(pills.map(\.id)).count == pills.count)
        check("the state pill leads", pills.first?.id == "state")
        check("and it says routing", pills.first?.label == loc("Routing"))
        for id in ["integrity", "rate", "buffer", "latency"] {
            check("a running path shows its \(id)", pills.contains { $0.id == id })
        }
        check(
            "nothing is recording, so there is no REC pill",
            !pills.contains { $0.id == "recording" })
        check(
            "the driver pill appears exactly when the driver is missing",
            pills.contains { $0.id == "driver" } == !model.isDriverInstalled)

        // The figure the strip used to carry was the buffer alone, which is the
        // flattering one: it ignores the output device's own latency and every
        // stage in the chain. It must never read lower than the buffer it
        // contains.
        guard let quality = model.pathQuality else { return }
        note(
            String(
                format: "path %.2f ms against a %.2f ms buffer, %.2f ms of DSP",
                model.pathLatencyMilliseconds, quality.bufferLatencyMilliseconds,
                model.addedLatencyMilliseconds))
        check(
            "the latency pill is more than the buffer",
            model.pathLatencyMilliseconds >= quality.bufferLatencyMilliseconds)
        check(
            "and it includes what the chain adds",
            model.pathLatencyMilliseconds
                >= quality.bufferLatencyMilliseconds + model.addedLatencyMilliseconds)
    }

    /// Compares the two string tables against each other.
    ///
    /// Seven long strings in the interface were never passed through `loc()`,
    /// and every one of them already had a Chinese translation sitting in the
    /// table unused — the table said the work was done and the interface showed
    /// English anyway. Nothing catches that but comparing the two sides, so it
    /// is compared on every run.
    private static func checkLocalisation() throws {
        guard let bundle = Bundle(path: AppResources.bundle.bundlePath) else {
            note("could not open the resource bundle")
            return
        }
        let tables = ["en", "zh-Hant"].map { language -> (String, [String: String]) in
            // Looked up by hand rather than through Bundle, for two reasons
            // that both bit. SwiftPM lowercases .lproj folder names and
            // Bundle's matching is case-sensitive; and the layout of a resource
            // bundle depends on which toolchain built it — flat under some,
            // wrapped in Contents/Resources under others. Reading a fixed path
            // found nothing and reported both tables missing, which looks
            // exactly like a localisation that never shipped.
            let path = stringsTable(in: bundle.bundlePath, language: language)
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
        displayed += EffectGroup.allCases.map { loc($0.title) }
        displayed += EffectGroup.allCases.map { loc($0.detail) }
        displayed += SourceChannelMode.allCases.map(\.title)
        displayed += TapMuteBehavior.allCases.map { loc($0.title) }
        displayed += RoutePreset.builtIn.map(\.name)
        displayed += RoutePreset.builtIn.map { loc($0.note) }
        displayed += HotkeyManager.Action.allCases.map(\.title)
        displayed += LevelCalibration.Role.allCases.map { loc($0.title) }
        displayed += EffectKind.Flavour.allCases.map { loc($0.title) }
        displayed += EffectKind.allCases.flatMap { kind in
            kind.parameters.map { loc($0.title) }
        }
        displayed += LoudnessTarget.allCases.map(\.title)
        displayed += LightingMode.allCases.map(\.title)

        // In Chinese, anything still made of Latin letters and spaces never
        // reached the table — a translated string would not be.
        // Names that are the same in every language are exempt: a platform is
        // called Discord in Chinese too, and "translating" it would be worse
        // than leaving it. The list is explicit rather than a heuristic,
        // because a heuristic here would quietly excuse a real omission.
        let properNouns: Set<String> = ["EBU R128", "YouTube", "Discord", "Spotify"]
        let stillEnglish = displayed.filter { text in
            text.count > 3 && text.allSatisfy { $0.isASCII } && !properNouns.contains(text)
        }
        check("every enum-built label is translated", stillEnglish.isEmpty)
        for text in stillEnglish.prefix(4) { note("not in the table: \(text)") }
    }

    /// Finds a language's table wherever the bundle happens to keep it.
    private static func stringsTable(in bundlePath: String, language: String) -> String? {
        let wanted = "\(language.lowercased()).lproj"
        let roots = [bundlePath, "\(bundlePath)/Contents/Resources"]
        for root in roots {
            let contents =
                (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            guard let folder = contents.first(where: { $0.lowercased() == wanted })
            else { continue }
            let path = "\(root)/\(folder)/Localizable.strings"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }

    /// Waits for something observable rather than for a number of seconds.
    ///
    /// Seventy-six fixed pauses add up to seventy-two seconds of the run, which
    /// is a third of it and none of it device work — it is waiting and hoping.
    /// Each one is sized for the worst case, because a pause that is sometimes
    /// too short is a check that sometimes fails for no reason, and that is
    /// worse than a slow one. So they were all sized generously and every run
    /// paid the worst case.
    ///
    /// This costs what the thing actually takes, with the old fixed pause as
    /// the ceiling. Unlike `waitUntil` it does not assert: a fixed pause never
    /// failed either, and the assertion that follows it is the real check. Its
    /// job is only to stop waiting once there is nothing left to wait for.
    ///
    /// Not every pause can become one of these. Two of them are measurement
    /// windows — "how much audio did the analyser count in two seconds of wall
    /// clock", "what does one poll cost averaged over four seconds" — and a
    /// window that ends early measures something else. Those stay.
    private static func pause(
        upTo seconds: TimeInterval, until condition: () -> Bool
    ) async {
        let ceiling = inWantedSection ? seconds : min(seconds, 0.05)
        let deadline = Date().addingTimeInterval(ceiling)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func pause(_ seconds: TimeInterval) async {
        // Enough for a run loop turn and a couple of IO cycles, which is what
        // the sections in between actually need — they are being carried along,
        // not measured.
        let wait = inWantedSection ? seconds : min(seconds, 0.05)
        try? await Task.sleep(for: .seconds(wait))
    }

    /// Starts the route again if it is down, and waits without asserting.
    ///
    /// Deliberately not a check. Some settings genuinely cannot come up on some
    /// machines — the echo canceller will not take every microphone — and a
    /// failure recorded here would say "routing is down" over and over instead
    /// of letting the section that cares report which setting it was. Whoever
    /// calls this asserts what they actually wanted to know afterwards.
    private static func bringRoutingBack(_ model: RouterModel) async {
        guard !model.isRunning else { return }
        model.start()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !model.isRunning {
            await pause(0.1)
        }
    }

    private static func waitUntil(
        _ description: String, _ condition: () -> Bool, timeout: TimeInterval
    ) async {
        // A shorter leash outside the filter. The condition still has to come
        // true — these are real device operations and skipping them would leave
        // the next section routing against nothing — but the generous timeouts
        // exist for the slow hardware case, and waiting the full fifteen
        // seconds for a device that will never start is exactly the cost being
        // avoided.
        let deadline = Date().addingTimeInterval(inWantedSection ? timeout : min(timeout, 6))
        while Date() < deadline, !condition() {
            await pause(0.05)
        }
        check(description, condition())
    }

    /// Waits for engine work to unwind, asserting nothing.
    ///
    /// `waitUntil` records a check, which is right when the waiting is itself
    /// the claim. Inside a loop that switches twenty-two things it would be
    /// twenty-two lines of noise around the four assertions that matter — and
    /// it is also the timing loop, so it polls tightly enough not to be most of
    /// what a fast change appears to cost.
    private static func settle(_ model: RouterModel, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(inWantedSection ? timeout : min(timeout, 6))
        while Date() < deadline, model.isBusy {
            await pause(0.01)
        }
    }

    /// The application list, checked against the HAL rather than against
    /// itself.
    ///
    /// Run with the route up, so the machine is demonstrably producing audio
    /// while the list is asked whether anything is. Two separate complaints
    /// live here and neither was visible to any check before: the list was
    /// empty until somebody pressed Refresh, because nothing else ever
    /// enumerated it; and the toggle offering nineteen background processes
    /// revealed two of them, because the row limit was applied after they were
    /// folded in.
    ///
    /// - Parameter model: The live model, mid-route.
    private static func checkApplicationList(model: RouterModel) async throws {
        try section("application list, with audio running")

        // What the panel and the window actually ask for.
        let panelLimit = 6
        let windowLimit = 8

        // First, let the HAL catch up with the route.
        //
        // The section immediately above stops the route and starts it again,
        // and `processIsRunningOutput` is the HAL's own bookkeeping about a
        // device that has just been handed back: it becomes true some time
        // after `isRunning` does, not with it. Measured here at **0.84 s**, and
        // at 0.01 s on two other runs — which is what makes it a race rather
        // than a delay somebody would have noticed. Everything below asks the
        // machine what is playing, so waiting once here is the difference
        // between checking the list and checking whether CoreAudio had finished
        // its paperwork.
        //
        // Before the enumeration rather than after it: the list is a snapshot,
        // so a refresh taken while the HAL still said nothing was playing
        // carries that answer into every assertion made against it afterwards.
        let askedAt = Date()
        if model.isRunning {
            await pause(
                upTo: 5.0,
                until: {
                    ((try? AudioProcesses.all(includingSilent: true)) ?? [])
                        .contains(where: \.isPlaying)
                })
            note(
                String(
                    format: "the HAL took %.2fs to say anything was playing",
                    -askedAt.timeIntervalSinceNow))
        }

        // Nobody has refreshed since the route started. This is the call the
        // list itself makes when it appears, and it has to be enough.
        let before = model.appsRefreshedAt
        model.refreshAppsIfStale(olderThan: 0)
        check("appearing is enough to enumerate", model.appsRefreshedAt != before)
        check("the list is not empty while audio is running", !model.availableApps.isEmpty)
        note("\(model.availableApps.count) application(s)")

        // And it does not re-enumerate on every redraw: 12 to 25 ms warm, and
        // this list lives inside a disclosure that redraws with the meters.
        let settled = model.appsRefreshedAt
        model.refreshAppsIfStale()
        check("a redraw a moment later does not re-enumerate", model.appsRefreshedAt == settled)

        // The assertion the empty list should always have had to survive:
        // whatever the HAL says is producing audio is in the list. A process
        // with no bundle identifier used to be dropped here, silently, which is
        // every command-line player there is.
        let processes = (try? AudioProcesses.all(includingSilent: true)) ?? []
        let playing = processes.filter(\.isPlaying)
        let listed = Set(model.availableApps.flatMap(\.processIDs))
        note("\(playing.count) of \(processes.count) process(es) playing")
        check(
            "every process the HAL says is playing is somewhere in the list",
            playing.allSatisfy { listed.contains($0.id) })
        // Conditioned on the route rather than asserted outright: this
        // application is itself writing to an output while it runs, so if the
        // route is up something is playing by definition. If it never came up
        // — a device held by another copy, an endpoint that refuses to start —
        // the machine really is silent and the failure to report is that one,
        // above, not this.
        if model.isRunning {
            check("the running route counts as something producing audio", !playing.isEmpty)
            // Playing sorts first, so it cannot be beyond the truncation either.
            check(
                "whatever is playing is on the first page of rows",
                model.appListing(limit: panelLimit).applications.contains(where: \.isPlaying))
        } else {
            note("no route is up, so nothing is producing audio to check the list against")
        }

        // The toggle. The number on it is a promise about how many rows appear.
        model.showsBackgroundApps = false
        let collapsed = model.appListing(limit: panelLimit)
        check("the daemons are held back by default", collapsed.background.isEmpty)
        check(
            "the applications fit the panel's limit", collapsed.applications.count <= panelLimit
        )
        let promised = model.hiddenAppCount
        note("\(collapsed.applications.count) shown, \(promised) offered by the toggle")

        model.showsBackgroundApps = true
        let expanded = model.appListing(limit: panelLimit)
        check(
            "expanding shows exactly as many as the toggle promised",
            expanded.background.count == promised)
        check(
            "the limit no longer swallows them",
            expanded.background.count
                == model.availableApps.filter { $0.isBackground && !$0.isPlaying }.count)
        // Nothing appears twice and nothing is lost between the two halves.
        let panelRows =
            expanded.applications.map(\.bundleID) + expanded.background.map(\.bundleID)
        check("no row is drawn twice", Set(panelRows).count == panelRows.count)
        check(
            "everything either shows, scrolls or is counted as overflow",
            panelRows.count + expanded.overflow == model.availableApps.count)

        // The window has more room, so it truncates less and reveals the same.
        let window = model.appListing(limit: windowLimit)
        check(
            "the window shows at least as much as the panel",
            window.applications.count >= expanded.applications.count
                && window.background.count == expanded.background.count)
        model.showsBackgroundApps = false
    }

    /// Each bus's own processing, which is the thing the mixer column now
    /// offers under the legend.
    ///
    /// The arithmetic is unit-tested against the real callback — a curve on bus
    /// A lifts A by six decibels and moves B by less than 0.05. What is checked
    /// here is everything above that: that the two buses have separate stores,
    /// that a slider reaches only its own, that both survive a save and a load,
    /// and that a file written before any of this existed still opens with its
    /// settings on the bus they used to run on.
    private static func checkBusProcessing(model: RouterModel) async throws {
        try section("per-bus processing")

        // A second bus for the duration, because one bus cannot demonstrate
        // that two are independent and this is the only check that drives the
        // model rather than the callback.
        let previousMonitor = model.monitorDeviceUID
        var borrowedMonitor = false
        if previousMonitor == nil,
            let second = model.monitorOptions.first(where: {
                $0.uid != model.selectedDestinationUID
            })
        {
            model.monitorDeviceUID = second.uid
            await waitUntil("a second bus came up", { !model.isBusy }, timeout: 15)
            borrowedMonitor = model.monitorDeviceUID == second.uid
        }
        defer {
            if borrowedMonitor { model.monitorDeviceUID = previousMonitor }
        }

        let buses = model.buses
        note(buses.map { "\($0.letter) \($0.deviceName)" }.joined(separator: " · "))
        guard let first = buses.first else {
            note("no bus in the path — skipped")
            return
        }

        // Every bus starts with nothing on it, or the ones that follow are
        // measuring whatever the last section left behind.
        for bus in buses { model.resetGraphicEQ(forBus: bus.id) }
        check(
            "every bus starts flat",
            buses.allSatisfy { model.graphicEQIsFlat(forBus: $0.id) })
        check("and nothing is being run", model.busCurves.isEmpty)

        model.setGraphicBand(4, at: 5, forBus: first.id)  // 1 kHz
        check(
            "moving one bus's band leaves it not flat", !model.graphicEQIsFlat(forBus: first.id)
        )
        if let curve = model.curve(forBus: first.id) {
            note(
                String(
                    format: "bus %@: %.1f dB at 1 kHz", first.letter,
                    curve.response(atHertz: 1000, sampleRate: 48000)))
            check(
                "and the band it moved is the one that moved",
                abs(curve.response(atHertz: 1000, sampleRate: 48000) - 4) < 0.4)
        } else {
            check("a moved band produces a curve", false)
        }

        // The whole point. Two buses, two mixes, two audiences.
        if buses.count > 1 {
            let other = buses[1]
            check(
                "the other bus is still flat",
                model.graphicEQIsFlat(forBus: other.id)
                    && model.curve(forBus: other.id) == nil)
            model.setGraphicBand(-3, at: 2, forBus: other.id)  // 120 Hz
            check(
                "and takes its own shape without disturbing the first",
                abs(model.graphicEQ(forBus: first.id)[5] - 4) < 0.001
                    && abs(model.graphicEQ(forBus: other.id)[2] + 3) < 0.001
                    && abs(model.graphicEQ(forBus: other.id)[5]) < 0.001)
            if let curve = model.curve(forBus: other.id) {
                note(
                    String(
                        format: "bus %@: %.1f dB at 120 Hz, %.1f dB at 1 kHz", other.letter,
                        curve.response(atHertz: 120, sampleRate: 48000),
                        curve.response(atHertz: 1000, sampleRate: 48000)))
            }
        } else {
            note("only one bus in the path — choose a monitor to exercise two")
        }

        // Reaching the engine is a separate claim from being in the model, and
        // this is the only check that makes it against a running route.
        let curves = model.busCurves
        let installed = model.applyCorrections()
        note("\(curves.count) curve(s) asked for, \(installed) reached an output")
        check(
            "every bus with a curve got one installed",
            !model.isRunning || installed == curves.count)

        // Persisted per bus, because the whole feature is worthless if it does
        // not survive a restart.
        let saved = PreferencesStore.load()
        check(
            "each bus's bands were saved under its own device",
            (saved.busGraphicEQ?[first.id]?[5]).map { abs($0 - 4) < 0.001 } ?? false)
        check(
            "and the file still carries the flat pair an older build would read",
            saved.graphicEQ?.count == 10)

        // A file from before buses had their own processing must open with its
        // settings where they used to run — on the monitor when there was one,
        // and never on the mix the far end hears.
        var legacy = Preferences.default
        legacy.busGraphicEQ = [:]
        legacy.busHeadphoneProfiles = [:]
        legacy.graphicEQ = [0, 0, 0, 0, 0, 5, 0, 0, 0, 0]
        legacy.headphoneProfileName = "Old Headphones"
        legacy.destinationDeviceUID = "far-end"
        legacy.monitorDeviceUID = "headphones"
        let migrated = RouterModel.busProcessing(from: legacy)
        check(
            "an old file's tone lands on the bus it used to run on",
            migrated.graphic["headphones"]?[5] == 5 && migrated.graphic["far-end"] == nil)
        check(
            "and so does its correction",
            migrated.profiles["headphones"] == "Old Headphones"
                && migrated.profiles["far-end"] == nil)
        legacy.monitorDeviceUID = nil
        let withoutMonitor = RouterModel.busProcessing(from: legacy)
        check(
            "with no monitor it lands on the destination instead",
            withoutMonitor.graphic["far-end"]?[5] == 5)

        // Put it back: everything after this reads the same model.
        for bus in buses { model.resetGraphicEQ(forBus: bus.id) }
        check("flattening every bus stops running anything", model.busCurves.isEmpty)
        check("no error was reported", model.lastError == nil)
        check("the route did not go down", model.isRunning)

        try await checkChainAlignment(model: model)
        try await checkOBSLink(model: model)
    }

    /// The link to OBS, as far as it can be driven with OBS not installed.
    ///
    /// What is checked here is everything that does not need the far end: the
    /// number this application would tell OBS, that it is the chain's latency
    /// with the sign the protocol wants, and that a connection to nothing comes
    /// back promptly with a sentence naming the switch that is off — which is
    /// the first thing almost everybody meets, because obs-websocket ships
    /// disabled.
    ///
    /// The handshake itself is asserted against a stub server in the unit
    /// tests. Nothing anywhere asserts OBS's *behaviour*, and that is stated in
    /// `RESEARCH.md` rather than implied by a green run.
    private static func checkOBSLink(model: RouterModel) async throws {
        try section("obs link")

        let link = model.obsLink
        check("it starts disconnected", link.state == .off && !link.isConnected)
        check("and says so in a sentence", link.summary == loc("Not connected"))
        check(
            "the settings window has somewhere to show it",
            PreferencesWindow.Section.allCases.contains(.streaming))

        // The offset is a fact about this application's own audio, so it has to
        // read correctly with nothing connected at all.
        let frames = model.chainAlignment.chain
        let rate = model.pathQuality?.sampleRate ?? 48000
        let offset = model.obsSyncOffsetMilliseconds
        note(String(format: "chain %d frames at %.0f Hz, offset %.0f ms", frames, rate, offset))
        check("the offset is never positive", offset <= 0)
        check(
            "and it is the chain's latency in milliseconds",
            abs(offset + (Double(frames) / rate * 1000).rounded()) < 0.001
                || offset == -950)
        check("nothing has been sent yet", link.pushedOffsetMilliseconds == nil)

        // Port 1 needs root to bind, so nothing is listening on it and nothing
        // can start listening on it while this runs. A random high port could
        // belong to something.
        link.host = "127.0.0.1"
        link.port = 1
        let started = Date()
        await link.connect()
        let elapsed = Date().timeIntervalSince(started)
        note(String(format: "a closed port answered in %.2fs", elapsed))
        check("a closed port fails rather than hangs", elapsed < 6)
        if case .failed(let reason) = link.state {
            check(
                "and the failure names the switch that is off",
                reason.contains("WebSocket") || reason.contains("WebSocket 伺服器"))
        } else {
            check("a closed port fails", false)
        }
        check(
            "nothing was sent to a connection that never opened",
            link.pushedOffsetMilliseconds == nil)

        // Muting with no link must be silent rather than an error: the mirror
        // is off by default and a person who never opens this section should
        // never see anything about it.
        let wasMuted = model.isInputMuted
        model.isInputMuted = !wasMuted
        model.isInputMuted = wasMuted
        check("muting with no link says nothing", model.lastError == nil)

        await link.disconnect()
        check("disconnecting puts it back", link.state == .off)
        link.port = OBSConnection.defaultPort
        check("no error was reported", model.lastError == nil)
        check("the route did not go down", model.isRunning)
    }

    /// The chain's latency has to reach something that moves a sample.
    ///
    /// It was measured, stored and shown in the interface for the whole life of
    /// the effect chain, and nothing used it: the microphone came out of the
    /// chain late and the tapped applications came out on time, so the mix was
    /// the voice behind the backing track by the length of the chain. The
    /// arrival frames are asserted against the real callback in the unit tests;
    /// what is checked here is that switching a stage on actually hands the
    /// number to the running graph.
    private static func checkChainAlignment(model: RouterModel) async throws {
        try section("chain alignment")

        let before = model.chainAlignment
        note("chain \(before.chain) frames, aligning \(before.applied)")
        check("with no stage on, nothing is held back", before.applied == 0)

        let originalEffects = model.enabledEffects
        model.setEffect(.voiceIsolation, enabled: true)
        await waitUntil("the chain came up", { !model.isBusy }, timeout: 20)
        let during = model.chainAlignment
        let rate = model.pathQuality?.sampleRate ?? 48000
        note(
            String(
                format: "chain %d frames (%.1f ms), aligning %d", during.chain,
                Double(during.chain) / rate * 1000, during.applied))
        note(
            "enabled: " + model.enabledEffects.map(\.rawValue).sorted().joined(separator: ", "))
        // Whether a particular unit reports any latency is the unit's business
        // and varies by machine — what must hold either way is that whatever it
        // reports is exactly what the graph holds back. The arrival frames for
        // a chain that does report some are asserted in the unit tests, which
        // do not need one to exist.
        check(
            "every path that skipped the chain is held back by exactly what it costs",
            during.applied == during.chain)
        if during.chain == 0 {
            note("this chain added no latency here — nothing to align")
        }
        check("no error was reported", model.lastError == nil)
        check("the route did not go down", model.isRunning)

        for kind in EffectKind.allCases where !originalEffects.contains(kind) {
            model.setEffect(kind, enabled: false)
        }
        await waitUntil("the chain went back", { !model.isBusy }, timeout: 20)
        check("switching it off stops holding anything back", model.chainAlignment.applied == 0)
    }

    private static func summarise() {
        releaseTheHardware()
        if !currentSection.isEmpty {
            sectionTimes.append((currentSection, Date().timeIntervalSince(sectionStarted)))
        }
        let slowest = sectionTimes.sorted { $0.1 > $1.1 }.prefix(6)
        let total = sectionTimes.reduce(0) { $0 + $1.1 }
        print("\n" + String(format: "%.0fs total. slowest:", total))
        for (name, seconds) in slowest {
            print(String(format: "  %5.1fs  %@", seconds, name))
        }

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
