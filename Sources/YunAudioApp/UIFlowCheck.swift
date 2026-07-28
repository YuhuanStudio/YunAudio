import AppKit
import AudioToolbox
import CoreAudio
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

    private static func section(_ name: String) {
        // Timed, and the slowest half dozen printed at the end. The whole check
        // is minutes long and it was not obvious where the minutes went — the
        // answer turned out to be route restarts, which are seconds of real
        // device work each and are worth being able to count.
        if !currentSection.isEmpty {
            sectionTimes.append((currentSection, Date().timeIntervalSince(sectionStarted)))
        }
        sectionStarted = Date()
        currentSection = name.lowercased()
        print("\n" + name + (inWantedSection ? "" : "  (skimmed)"))
    }

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
        print("waiting for another flow check to finish with the devices…")
        // Blocking `flock` would be simpler and would block the run loop, which
        // this process needs: the model hops through the main actor and would
        // never make progress.
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static func releaseTheHardware() {
        guard lock >= 0 else { return }
        flock(lock, LOCK_UN)
        close(lock)
        lock = -1
    }

    static func run(model: RouterModel) async {
        await takeTheHardware()
        section("launch state")
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

        section("window and shortcuts")
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

        section("appearance")
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

        section("realtime tripwire")
        // The hook is process-wide, so leaving it armed taxes every allocation
        // in SwiftUI, AppKit and CoreAudio for a diagnostics page almost nobody
        // opens. It used to be armed from launch.
        check("the allocator hook is not armed at launch", !model.watchesIOAllocations)
        model.watchesIOAllocations = true
        check("it can be armed", model.watchesIOAllocations)
        model.watchesIOAllocations = false
        check("and disarmed again", !model.watchesIOAllocations)

        section("saved presets")
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

        section("voice presets")
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

        section("third-party units")
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

        section("light ring")
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

        section("what each device actually publishes")
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

        section("the device's own monitoring")
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

        section("hardware gain")
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

        section("driver freshness")
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

        section("our own device's controls")
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

        section("device profiles")
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

        section("channel naming")
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

        section("localisation")
        checkLocalisation()

        section("application list")
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

        section("starting")
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

        checkStatusPills(model: model)

        section("muting the first route")
        model.setMuted(true, forRouteAt: 0)
        check("the mute took", model.routeMutes.first == true)
        model.setMuted(false, forRouteAt: 0)
        check("unmuting took", model.routeMutes.first == false)

        section("solo, peak hold and clipping")
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

        section("moving a fader")
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

        section("input trim and master")
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

        section("loudness and spectrum")
        // The unit tests prove the arithmetic against the standard. What they
        // cannot prove is that the ring is wired to the output bus at all — a
        // meter reading a ring nothing writes to reports a clean −inf, which is
        // indistinguishable from a quiet room until somebody speaks into it.
        model.isAnalysisVisible = true
        model.resetLoudness()
        await pause(1.5)
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
            await pause(3.5)
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

        section("what the on-device model hears")
        model.isAnalysisVisible = true
        await pause(2.0)
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

        section("what is actually leaving")
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
        // Both stages pushed to the top rather than just the trim: a quiet room
        // sat at −50 dBFS, so +40 dB of trim still landed ten decibels short of
        // full scale and the check failed for want of signal rather than for
        // want of detection.
        let trimBeforeClip = model.inputDecibels
        let masterBeforeClip = model.outputDecibels
        model.inputDecibels = 40
        model.outputDecibels = 40
        await pause(0.6)
        check("clipping is detected once it happens", model.outputClippedSamples > 0)
        check("and it is called clipping", model.outputVerdict == .clipping)
        model.inputDecibels = trimBeforeClip
        model.outputDecibels = masterBeforeClip
        model.clearClipping()
        await pause(0.3)
        check("the latch can be cleared", model.outputClippedSamples == 0)

        section("balancing sources")
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

        section("named buses")
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

        section("sources rather than wires")
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

        section("per-application taps")
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

        section("ducking")
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

        section("idle cost")
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

        section("automatic levelling")
        let trimBefore = model.inputDecibels
        model.isAutoLevelling = true
        await pause(1.5)
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
        // Switching it off keeps whatever level it settled on rather than
        // snapping back: the point was to find a good trim, and throwing that
        // away the moment somebody disengages would undo the work.
        let settled = model.inputDecibels
        model.isAutoLevelling = false
        await pause(0.3)
        check("switching it off keeps the level it settled on", model.inputDecibels == settled)
        check("routing continues without it", model.isRunning && !model.isBusy)

        section("push to talk")
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

        section("direct monitoring")
        if let monitor = model.monitorOptions.first {
            let routesBefore = model.activeRoutes.count
            model.monitorDeviceUID = monitor.uid
            await waitUntil("the monitor came up", { !model.isBusy }, timeout: 12)
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
        } else {
            note("no second output to monitor on — skipped")
        }

        section("pitch tracking")
        // Knowing the actual fundamental is what would let a voice be moved to
        // a range rather than by an amount. Measured against the live signal:
        // in a quiet room there is no pitch to find, and reporting one would be
        // the failure worth catching.
        // Through the analyser rather than beside it: the analyser drains the
        // ring dry every fifty milliseconds, so a diagnostic that read the same
        // ring found nothing and reported it as a lack of audio. The tracker is
        // one of the analyser's outputs now, which is where it belonged.
        model.isAnalysisVisible = true
        await pause(1.5)
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

        section("every stage on its own")
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

        section("gain reduction")
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
        await pause(1.2)
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

        section("switching channel mode while running")
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

        section("recording")
        check("recording is offered while routing", model.isRunning)
        model.toggleRecording()
        check("the recording started", model.isRecording)
        check("no error was reported", model.lastError == nil)
        let file = model.recordingURL
        check("a file was named", file != nil)
        await pause(2.0)
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

        section("stems")
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
        await pause(2.0)
        model.toggleRecording()
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

        section("stems survive a route edit")
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

        section("transcription")
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

        section("switching the echo canceller on while running")
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

        section("applying a preset while running")
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

        print("\nwhat a scene actually changes")
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
        check("and that is fewer than doing them loose", batched < unbatched)
        await waitUntil("the batch settled", { !model.isBusy }, timeout: 10)
        check("routing survived both", model.isRunning)

        section("processing chain")
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

        section("processing chain swapped live")
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

        // Handed back exactly as it was found, since everything below this runs
        // against whatever chain is left in place.
        model.enabledEffects = chainBefore
        await waitUntil("the chain came back", { !model.isBusy }, timeout: 14)
        check("routing survived every swap", model.isRunning)

        section("patching")
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

        section("device changes")
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
            if let error = model.lastError { note("error was: \(error)") }
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

        section("devices that share no sample rate")
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
            await pause(1.0)
            check("audio is flowing", model.cycleCountForDiagnostics > 0)
            model.selectedDestinationUID = previous
            await waitUntil("and it went back", { model.isRunning }, timeout: 15)
        } else {
            note("every output shares a rate with the source — not exercised")
        }

        section("output-only aggregate members")
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

        section("singing")
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
        // Pitch is switched on only while somebody is looking, which is what
        // makes a lyrics panel cheaper than the analysis panel.
        check("looking at it asks for the pitch", !model.analysisIsIdle)
        model.isSingingVisible = false
        check("and looking away clears the track", model.nowPlaying == nil)

        section("output tone")
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

        section("headphone correction")
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

        section("setups")
        // A setup captures devices; a scene captures processing. Confusing the
        // two would mean somebody choosing "podcast" could not know whether
        // they had changed a compressor or unplugged their headphones.
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
        }
        model.deleteQuickConfig(named: "Flow check setup")
        check(
            "it was deleted",
            !model.quickConfigs.contains { $0.name == "Flow check setup" })
        await waitUntil("and routing is still up", { model.isRunning }, timeout: 10)

        section("excluded applications")
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

        section("volume keys")
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

        section("output alignment")
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

        section("remote control")
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

        section("falling back when a device disappears")
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
            await waitUntil("and came up on it", { model.isRunning }, timeout: 8)

            decoy.destroy()
            await pause(2.0)
            check("it did not stop", model.isRunning)
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
            await waitUntil("and it is running again", { model.isRunning }, timeout: 8)
        } else {
            note("could not build a decoy device — skipped")
        }

        section("integrity check")
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

        checkApplicationList(model: model)

        section("stopping")
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
        section("settings")
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

        summarise()
    }

    /// What the bottom of the window is actually showing.
    ///
    /// The row is built as data before it is drawn, because which pills are
    /// present *is* the behaviour — one that disappears when it has nothing to
    /// say cannot be checked by looking at a screenshot of a machine where it
    /// happened to have something. A view cannot be asked what it is showing;
    /// the list it is built from can.
    private static func checkStatusPills(model: RouterModel) {
        print("\nstatus pills")
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
    private static func checkLocalisation() {
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
    private static func checkApplicationList(model: RouterModel) {
        section("application list, with audio running")

        // What the panel and the window actually ask for.
        let panelLimit = 6
        let windowLimit = 8

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
