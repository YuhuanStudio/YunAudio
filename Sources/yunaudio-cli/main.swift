import AVFoundation
import CoreAudio
import Foundation
import YunAudioEngine
import YunAudioHAL
import YunAudioRazer

// A verification harness for the HAL layer. Everything the GUI will rely on is
// readable here first, so device quirks surface before any UI exists.

func transportLabel(_ transport: AudioTransport) -> String {
    switch transport {
    case .builtIn: "built-in"
    case .usb: "USB"
    case .thunderbolt: "Thunderbolt"
    case .hdmi: "HDMI"
    case .displayPort: "DisplayPort"
    case .bluetooth: "Bluetooth"
    case .airPlay: "AirPlay"
    case .virtual: "virtual"
    case .aggregate: "aggregate"
    case .pci: "PCI"
    case .fireWire: "FireWire"
    case .avb: "AVB"
    case let .other(raw): "other \(fourCharDescription(raw))"
    case .unknown: "unknown"
    }
}

func rateList(_ rates: [Double]) -> String {
    guard !rates.isEmpty else { return "—" }
    return rates.map { rate in
        rate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(rate / 1000))k" : String(format: "%.1fk", rate / 1000)
    }.joined(separator: " ")
}

func describe(_ device: AudioDevice, isDefaultInput: Bool, isDefaultOutput: Bool) {
    var badges: [String] = []
    if isDefaultInput { badges.append("default-in") }
    if isDefaultOutput { badges.append("default-out") }
    if device.isRunningSomewhere { badges.append("running") }
    if !device.isAlive { badges.append("DEAD") }
    let badgeText = badges.isEmpty ? "" : "  [\(badges.joined(separator: " "))]"

    print("\n\(device.name)\(badgeText)")
    print("  uid          \(device.uid)")
    print("  transport    \(transportLabel(device.transport))", terminator: "")
    if let manufacturer = device.manufacturer {
        print("   ·  \(manufacturer)")
    } else {
        print("")
    }
    print("  channels     \(device.inputChannels) in / \(device.outputChannels) out")
    print(
        "  sample rate  \(Int(device.nominalSampleRate)) Hz  (available: \(rateList(device.availableSampleRates)))"
    )

    // Domains are four-char codes; 'main' is the Mac's own audio clock, which
    // built-in and synchronous USB devices slave to. A device with its own
    // crystal (asynchronous USB) publishes nothing.
    let domain =
        device.clockDomain.map { "\(fourCharDescription($0)) (\($0))" } ?? "not published"
    print("  clock domain \(domain)")

    if let frames = device.currentBufferFrameSize {
        let ms =
            device.nominalSampleRate > 0
            ? String(format: " (%.2f ms)", Double(frames) / device.nominalSampleRate * 1000)
            : ""
        print("  buffer       \(frames) frames\(ms)")
    }

    if device.hasInput {
        let frames = device.latencyFrames(scope: kAudioObjectPropertyScopeInput)
        let ms =
            device.nominalSampleRate > 0
            ? String(format: " (%.2f ms)", Double(frames) / device.nominalSampleRate * 1000)
            : ""
        print("  in latency   \(frames) frames\(ms)")
    }
    if device.hasOutput {
        let frames = device.latencyFrames(scope: kAudioObjectPropertyScopeOutput)
        let ms =
            device.nominalSampleRate > 0
            ? String(format: " (%.2f ms)", Double(frames) / device.nominalSampleRate * 1000)
            : ""
        print("  out latency  \(frames) frames\(ms)")
    }

    let inputStreams = device.inputStreams
    if !inputStreams.isEmpty {
        print("  input streams")
        for stream in inputStreams {
            let current = stream.currentPhysicalFormat.map(String.init(describing:)) ?? "—"
            print(
                "    · stream \(stream.id) starting at ch \(stream.startingChannel): \(current)"
            )
            for format in stream.availablePhysicalFormats {
                let marker = format.encoding.isFloat ? "  ← FLOAT" : ""
                print("        \(format)\(marker)")
            }
        }
    }

    if device.supportsFloatInput {
        print("  ** hardware presents a float input format **")
    }
}

// MARK: - Route mode

/// Brings up a real route and reports what the engine sees, so the audio path
/// can be verified before any UI exists.
func runRoute(
    sourceMatch: String, destinationMatch: String, seconds: Double,
    voiceIsolation: Bool = false
) throws {
    let devices = try AudioDevices.all()
    guard let source = devices.first(where: { $0.name.contains(sourceMatch) && $0.hasInput })
    else {
        print("no input device matching \"\(sourceMatch)\"")
        exit(1)
    }
    guard
        let destination = devices.first(where: {
            $0.name.contains(destinationMatch) && $0.hasOutput
        })
    else {
        print("no output device matching \"\(destinationMatch)\"")
        exit(1)
    }

    print("source      \(source.name)  (\(source.inputChannels) in)")
    print("destination \(destination.name)  (\(destination.outputChannels) out)")

    let pairs = min(2, min(source.inputChannels, destination.outputChannels))
    let signalRoutes = (0..<pairs).map { channel in
        Route(
            source: ChannelRef(deviceUID: source.uid, channel: channel),
            destination: ChannelRef(deviceUID: destination.uid, channel: channel))
    }
    print(
        "routes      \(signalRoutes.map { "ch\($0.source.channel + 1)→ch\($0.destination.channel + 1)" }.joined(separator: ", "))"
    )

    // BlackHole is a loopback: whatever is written to its output reappears on
    // its input. Since it is already a member of the aggregate, reading its
    // input in the same IOProc proves the signal actually landed there rather
    // than merely being read off the microphone. Gain 0 keeps this route
    // silent — peaks are metered pre-gain, so it is a pure probe.
    var allRoutes = signalRoutes
    let probeChannel = destination.outputChannels - 1
    if destination.inputChannels > 0 {
        allRoutes.append(
            Route(
                source: ChannelRef(deviceUID: destination.uid, channel: 0),
                destination: ChannelRef(deviceUID: destination.uid, channel: probeChannel),
                gain: 0))
        print("probe       \(destination.name) in ch1 (loopback verification)")
    }
    let routes = allRoutes

    RoutingEngine.enableAllocationTripwire()
    let violationsBefore = RoutingEngine.allocationViolations

    let engine = RoutingEngine()
    try engine.start(
        sourceDeviceUID: source.uid,
        destinationDeviceUID: destination.uid,
        routes: routes,
        voiceIsolation: voiceIsolation ? VoiceIsolationSettings() : nil)
    if voiceIsolation {
        print("isolation   on · adds \(engine.voiceIsolationLatencyFrames) frames")
    }

    if let quality = engine.pathQuality {
        print("aggregate   \(engine.aggregate?.uid ?? "—")")
        print("rate        \(Int(quality.sampleRate)) Hz")
        print(
            String(
                format: "buffer      %d frames (%.2f ms)",
                quality.bufferFrames, quality.bufferLatencyMilliseconds))
        print(
            "path        \(quality.isBitExact ? "bit-exact" : "resampled — drift correction on \(quality.driftCorrectedDeviceUIDs.joined(separator: ", "))")"
        )
    }
    if let publisher = ClockAnchorPublisher(), publisher.driverSupportsClockLocking {
        print("clock       YunAudio driver supports clock locking")
    } else {
        print(
            "clock       destination cannot be clock-locked (not the YunAudio driver, or it predates clock anchors)"
        )
    }

    print("\nrunning for \(Int(seconds))s — speak into the microphone\n")
    let deadline = Date().addingTimeInterval(seconds)
    var lastCycle: UInt64 = 0
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        let peaks = engine.routePeaks
        let cycles = engine.cycleCount
        let bars = peaks.map { peak -> String in
            let db = peak > 0 ? 20 * log10(peak) : -120
            let filled = max(0, min(20, Int((db + 60) / 3)))
            return String(repeating: "█", count: filled)
                + String(repeating: "·", count: 20 - filled)
        }
        let delta = cycles - lastCycle
        lastCycle = cycles
        let lock =
            engine.isClockLocked
            ? String(format: "LOCKED %.6f", engine.measuredRateRatio) : "unlocked"
        print("  cycles +\(delta)  \(bars.joined(separator: "  "))  \(lock)")
    }

    // Re-read after the run: the clock lock takes about a second and a half to
    // converge, so the verdict printed at startup is always the pessimistic one.
    if let quality = engine.pathQuality {
        print("")
        if quality.isBitExact {
            print(
                String(
                    format:
                        "path        bit-exact — no resampling configured, clock locked at %.6f",
                    engine.measuredRateRatio))
            print(
                "            (configuration-level claim; --selftest is the sample-level proof)")
        } else if quality.hasProcessing {
            print("path        processed — voice isolation is altering the signal by design")
        } else if quality.driftCorrectedDeviceUIDs.isEmpty {
            print(
                "path        no drift correction configured, but the clock lock is not holding")
        } else {
            print(
                "path        resampled — drift correction on "
                    + quality.driftCorrectedDeviceUIDs.joined(separator: ", "))
        }
    }

    engine.stop()
    let violations = RoutingEngine.allocationViolations - violationsBefore
    print("stopped. total IO cycles: \(lastCycle)")
    print(
        String(
            format: "realtime path: %llu allocations over %llu cycles (%.1f per cycle)",
            violations, lastCycle,
            lastCycle > 0 ? Double(violations) / Double(lastCycle) : 0))
    if voiceIsolation {
        print("isolation render failures: \(engine.voiceIsolationFailures)")
    }
    if lastCycle == 0 {
        print("WARNING: the device never called back — no audio moved.")
        exit(1)
    }
}

// MARK: - Selftest mode

/// Sends a deterministic sequence through the real routing path and compares
/// what returns, sample for sample. This is the only claim of losslessness that
/// does not rest on configuration.
func runSelftest(sourceMatch: String, destinationMatch: String) throws {
    let devices = try AudioDevices.all()
    guard let source = devices.first(where: { $0.name.contains(sourceMatch) && $0.hasInput }),
        let destination = devices.first(where: {
            $0.name.contains(destinationMatch) && $0.hasOutput && $0.inputChannels > 0
        })
    else {
        print(
            "need an input device matching \"\(sourceMatch)\" and a loopback-capable output matching \"\(destinationMatch)\""
        )
        exit(1)
    }

    // Watches for any allocation made on the IO thread. Reading the realtime
    // code and concluding it is allocation-free is not evidence; this is.
    RoutingEngine.enableAllocationTripwire()
    let violationsBefore = RoutingEngine.allocationViolations

    print("clock master  \(source.name)")
    print("device under test  \(destination.name)")

    let engine = RoutingEngine()
    try engine.start(
        sourceDeviceUID: source.uid,
        destinationDeviceUID: destination.uid,
        routes: [],
        selftest: true)

    if let quality = engine.pathQuality {
        print("rate          \(Int(quality.sampleRate)) Hz")
        print(
            "drift correction  "
                + (quality.driftCorrectedDeviceUIDs.isEmpty
                    ? "none" : quality.driftCorrectedDeviceUIDs.joined(separator: ", ")))
    }

    print("\ncapturing…")
    while engine.selftestProgress < 1.0 {
        Thread.sleep(forTimeInterval: 0.25)
        print(
            String(
                format: "  %.0f%%  %@", engine.selftestProgress * 100,
                engine.isClockLocked
                    ? String(format: "clock locked %.6f", engine.measuredRateRatio)
                    : "clock unlocked"))
    }

    let result = engine.evaluateSelftest()
    let locked = engine.isClockLocked
    let ratio = engine.measuredRateRatio
    engine.stop()

    print("")
    guard let result else {
        print("selftest produced no result")
        exit(1)
    }
    print(result.summary)
    if locked { print(String(format: "clock lock held at %.6f throughout", ratio)) }

    let violations = RoutingEngine.allocationViolations - violationsBefore
    if violations == 0 {
        print("realtime path: 0 allocations on the IO thread")
    } else {
        print(
            "realtime path: \(violations) ALLOCATIONS on the IO thread — the no-allocation rule is broken"
        )
    }
    exit(result.isBitExact && violations == 0 ? 0 : 1)
}

// MARK: - Run

// Restores devices to a sane rate.
//
// Routing has to align sample rates across the devices it binds together, and
// that change persists on the hardware after the tool exits. A tool that
// reconfigures someone's hardware has to be able to put it back.
// What is actually going on right now: live taps, and which devices each
// audio-using process has open.
// Sends one application's audio to a device of its own, the way SoundSource
// does — and silences the copy the application would otherwise play itself.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "send-app" {
    let appMatch = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Discord"
    let deviceMatch = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "MacBook"
    let all = (try? AudioDevices.all()) ?? []
    guard let clock = all.first(where: { $0.hasInput && !$0.transport.isVirtual }),
        let target = all.first(where: { $0.name.contains(deviceMatch) && $0.hasOutput })
    else {
        print("need an input to act as clock master and an output to send to")
        exit(1)
    }
    let processes = ((try? AudioProcesses.all(includingSilent: true)) ?? []).filter {
        $0.name.localizedCaseInsensitiveContains(appMatch)
            || ($0.bundleID?.localizedCaseInsensitiveContains(appMatch) ?? false)
    }
    guard !processes.isEmpty else {
        print("no process matching \"\(appMatch)\"")
        exit(1)
    }

    // mutedWhenTapped is what makes this a redirection rather than a duplication:
    // the application stops playing to its own output for as long as the tap is
    // being read.
    let tap = try ProcessTap(
        processIDs: processes.map(\.id), muteBehavior: .mutedWhenTapped)
    print("\(processes.count) process(es) of \(appMatch) → \(target.name)")
    print("clock master: \(clock.name)\n")

    let engine = RoutingEngine()
    let channels = min(2, Int(tap.format?.mChannelsPerFrame ?? 2), target.outputChannels)
    let routes = (0..<channels).map { channel in
        Route(
            source: ChannelRef(deviceUID: tap.uid, channel: channel),
            destination: ChannelRef(deviceUID: target.uid, channel: channel))
    }
    try engine.start(
        sourceDeviceUID: clock.uid,
        destinationDeviceUID: target.uid,
        routes: routes,
        taps: [tap])

    print("redirecting for 6s — play something in \(appMatch)\n")
    for _ in 0..<18 {
        Thread.sleep(forTimeInterval: 0.33)
        let bars = engine.routePeaks.map { peak -> String in
            let db = peak > 0 ? 20 * log10(peak) : -120
            let filled = max(0, min(20, Int((db + 60) / 3)))
            return String(repeating: "█", count: filled)
                + String(repeating: "·", count: 20 - filled)
        }
        print("  \(bars.joined(separator: "  "))")
    }
    engine.stop()
    exit(0)
}

// Records the routed signal to a file.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "record" {
    let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 5 : 5
    let all = (try? AudioDevices.all()) ?? []
    // Any input will do; the USB microphone is often unplugged.
    guard let source = all.first(where: { $0.hasInput && !$0.transport.isVirtual }),
        let destination = all.first(where: { $0.transport.isVirtual && $0.hasOutput })
    else {
        print("need an input and a virtual output")
        exit(1)
    }
    let engine = RoutingEngine()
    let routes = (0..<2).map { channel in
        Route(
            source: ChannelRef(deviceUID: source.uid, channel: 0),
            destination: ChannelRef(deviceUID: destination.uid, channel: channel))
    }
    try engine.start(
        sourceDeviceUID: source.uid, destinationDeviceUID: destination.uid, routes: routes)

    let url = try engine.startRecording(to: FileManager.default.temporaryDirectory)
    print("recording \(source.name) for \(Int(seconds))s")
    print("  → \(url.path)\n")
    for _ in 0..<Int(seconds * 2) {
        Thread.sleep(forTimeInterval: 0.5)
        print(String(format: "  %.1fs written", engine.recordingDuration))
    }
    // Read before stopping: stopRecording releases the recorder, and the
    // duration lives on it.
    let recorded = engine.recordingDuration
    engine.stopRecording()
    engine.stop()

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
    let expected = Int(recorded * 48000 * 2 * 4)
    print(String(format: "\n  %.1f s, %d bytes on disk", recorded, size))
    print(
        String(
            format: "  %.0f%% of what %.1f s of 48k stereo float32 should weigh",
            Double(size) / Double(max(expected, 1)) * 100, recorded))
    exit(size > 0 ? 0 : 1)
}

// Measures how the driver's reported latency and safety offset affect the path.
//
// The driver reports zero for both, which is unusual — real hardware reports a
// safety offset because the HAL needs headroom ahead of the IO cycle. Whether
// zero is fine or merely appears fine is an empirical question.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "driver-timing" {
    let all = (try? AudioDevices.all()) ?? []
    guard let source = all.first(where: { $0.hasInput && $0.transport == .usb }) else {
        print("need a USB input")
        exit(1)
    }
    let virtuals = all.filter { $0.transport.isVirtual && $0.inputChannels > 0 }
    guard !virtuals.isEmpty else {
        print("no virtual devices to compare")
        exit(1)
    }

    print("clock master: \(source.name)\n")
    // %s takes a C string; a Swift String through it reads a pointer that is
    // not one and crashes. %@ is the Swift form.
    print(
        String(
            format: "%-18@ %8@ %8@ %10@ %12@",
            "device", "in lat", "out lat", "buffer", "selftest"))

    for device in virtuals {
        let inLatency = device.latencyFrames(scope: kAudioObjectPropertyScopeInput)
        let outLatency = device.latencyFrames(scope: kAudioObjectPropertyScopeOutput)

        // Run the integrity check to see what the reported figures translate to.
        let engine = RoutingEngine()
        var verdict = "—"
        if (try? engine.start(
            sourceDeviceUID: source.uid, destinationDeviceUID: device.uid,
            routes: [], selftest: true)) != nil
        {
            while engine.selftestProgress < 1.0 { Thread.sleep(forTimeInterval: 0.2) }
            if let result = engine.evaluateSelftest() {
                verdict =
                    result.isBitExact
                    ? "exact @\(result.delayFrames)" : "MISMATCH"
            }
            engine.stop()
        }
        print(
            String(
                format: "%-18@ %8d %8d %10d %12@",
                String(device.name.prefix(18)), inLatency, outLatency,
                Int(device.currentBufferFrameSize ?? 0), verdict))
    }
    exit(0)
}

// Proves a route change no longer interrupts audio.
//
// Cycles are counted across a topology change. A restart shows a gap of about
// a hundred milliseconds' worth of missing cycles; a swap shows none.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "swap" {
    let all = (try? AudioDevices.all()) ?? []
    guard let source = all.first(where: { $0.hasInput && $0.transport == .usb }),
        let destination = all.first(where: { $0.hasOutput && $0.transport.isVirtual })
    else {
        print("need a USB input and a virtual output")
        exit(1)
    }
    print("\(source.name) → \(destination.name)\n")

    let engine = RoutingEngine()
    let one = [
        Route(
            source: ChannelRef(deviceUID: source.uid, channel: 0),
            destination: ChannelRef(deviceUID: destination.uid, channel: 0))
    ]
    let two =
        one + [
            Route(
                source: ChannelRef(deviceUID: source.uid, channel: 0),
                destination: ChannelRef(deviceUID: destination.uid, channel: 1))
        ]
    try engine.start(
        sourceDeviceUID: source.uid, destinationDeviceUID: destination.uid, routes: one)
    Thread.sleep(forTimeInterval: 0.5)

    func cyclesAcross(_ change: () -> Void) -> UInt64 {
        let before = engine.cycleCount
        let mark = Date()
        change()
        Thread.sleep(forTimeInterval: 0.5)
        let elapsed = Date().timeIntervalSince(mark)
        let observed = engine.cycleCount - before
        let expected = UInt64(
            elapsed * (engine.pathQuality.map { $0.sampleRate } ?? 48000)
                / Double(engine.pathQuality.map { $0.bufferFrames } ?? 128))
        print(
            String(
                format: "  %llu cycles observed, %llu expected — %.0f%% delivered",
                observed, expected, Double(observed) / Double(max(expected, 1)) * 100))
        return observed
    }

    print("swapping the route set in place:")
    _ = cyclesAcross { _ = engine.updateRoutes(two) }
    print("  routes now: \(engine.currentRoutes.count)")
    engine.stop()
    exit(0)
}

// How long the blocking parts take, because start() runs on the main thread.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "timing" {
    let all = (try? AudioDevices.all()) ?? []
    guard let source = all.first(where: { $0.hasInput && $0.transport == .usb }),
        let destination = all.first(where: { $0.hasOutput && $0.transport.isVirtual })
    else { print("need a USB input and a virtual output"); exit(1) }

    print("source \(source.name) → \(destination.name)\n")
    let routes = [
        Route(
            source: ChannelRef(deviceUID: source.uid, channel: 0),
            destination: ChannelRef(deviceUID: destination.uid, channel: 0))
    ]

    var startTimes: [Double] = []
    var stopTimes: [Double] = []
    for _ in 0..<5 {
        let engine = RoutingEngine()
        var mark = Date()
        try engine.start(
            sourceDeviceUID: source.uid, destinationDeviceUID: destination.uid,
            routes: routes)
        startTimes.append(Date().timeIntervalSince(mark) * 1000)
        mark = Date()
        engine.stop()
        stopTimes.append(Date().timeIntervalSince(mark) * 1000)
    }
    func report(_ label: String, _ values: [Double]) {
        let sorted = values.sorted()
        print(
            String(
                format: "  %@  median %.0f ms, worst %.0f ms",
                label, sorted[sorted.count / 2], sorted.last ?? 0))
    }
    report("start", startTimes)
    report("stop ", stopTimes)
    print("\n  Both run on the main thread today, so this is how long the UI stalls.")
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "diagnose" {
    let taps = AudioProcesses.liveTaps()
    print("live process taps: \(taps.count)")
    for tap in taps { print("  · \(tap.uid)  (object \(tap.id))") }

    print("\nprocesses holding audio devices:")
    let devices = (try? AudioDevices.all()) ?? []
    let byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
    for process in (try? AudioProcesses.all(includingSilent: true)) ?? [] {
        let inputs = process.devices(scope: kAudioObjectPropertyScopeInput)
        let outputs = process.devices(scope: kAudioObjectPropertyScopeOutput)
        guard !inputs.isEmpty || !outputs.isEmpty else { continue }
        let inNames = inputs.map { byID[$0] ?? "object \($0)" }.joined(separator: ", ")
        let outNames = outputs.map { byID[$0] ?? "object \($0)" }.joined(separator: ", ")
        print("  \(process.name)")
        if !inputs.isEmpty { print("     in:  \(inNames)") }
        if !outputs.isEmpty { print("     out: \(outNames)") }
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "reset" {
    let target =
        CommandLine.arguments.count > 2
        ? Double(CommandLine.arguments[2]) ?? 48000 : 48000
    do {
        for device in try AudioDevices.all() {
            guard device.availableSampleRates.contains(target),
                let current = device.currentSampleRate, current != target
            else { continue }
            do {
                try device.setNominalSampleRate(target)
                print("  \(device.name): \(Int(current)) Hz → \(Int(target)) Hz")
            } catch {
                print("  \(device.name): could not change rate — \(error)")
            }
        }
        print("done")
    } catch {
        print("reset failed: \(error)")
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "razer" {
    if CommandLine.arguments.contains("--dump") {
        RazerDevice.dumpCandidates()
        exit(0)
    }
    let devices = RazerDevice.discover()
    guard !devices.isEmpty else {
        print("no Razer device exposing a vendor-defined HID usage page")
        print("run with --dump to see what the Razer devices actually publish")
        exit(1)
    }
    for device in devices {
        print("\(device.productName)  ·  0x\(String(format: "%04X", device.productID))")
        print(
            "  vendor pages "
                + device.vendorUsagePages
                .map { String(format: "0x%04X", $0) }.joined(separator: " "))
        for line in device.reportDescriptorSummary() { print("  \(line)") }
        // Read-only throughout. Reading a feature report asks the device for its
        // current state; the write side would mean guessing command bytes on
        // hardware that keeps persistent configuration.
        do {
            let bytes = try device.readFeatureReport(id: 0x07, size: 63)
            print("  feature 0x07 (\(bytes.count) bytes):")
            for offset in stride(from: 0, to: bytes.count, by: 16) {
                let slice = bytes[offset..<min(offset + 16, bytes.count)]
                let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
                print(String(format: "    %04X  %@", offset, hex))
            }
        } catch {
            print("  feature 0x07  \(error)")
        }
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "apps" {
    do {
        let applications = try AudioApplications.grouped()
        let foreground = applications.filter { !$0.isBackground }
        print(
            "tappable applications — \(foreground.count) foreground, "
                + "\(applications.count) total\n")
        for application in applications {
            let marker = application.isPlaying ? "▶" : " "
            let origin = application.isBackground ? "  (background)" : ""
            let folded = application.processCount > 1 ? "  ×\(application.processCount)" : ""
            print(
                "  \(marker) \(application.name)  ·  \(application.bundleID)\(folded)\(origin)")
        }
    } catch {
        print("could not enumerate processes: \(error)")
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "tap" {
    let match = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Discord"
    do {
        let processes = try AudioProcesses.all(includingSilent: true)
        let matches = processes.filter {
            $0.name.localizedCaseInsensitiveContains(match)
                || ($0.bundleID?.localizedCaseInsensitiveContains(match) ?? false)
        }
        guard !matches.isEmpty else {
            print("no process matching \"\(match)\"")
            exit(1)
        }
        print("tapping \(matches.count) process(es):")
        for process in matches {
            print(
                "  · \(process.name)  pid \(process.pid)\(process.isPlaying ? "  [playing]" : "")"
            )
        }
        let tap = try ProcessTap(
            processIDs: matches.map(\.id), muteBehavior: .unmuted)
        print("\ntap uid     \(tap.uid)")
        if let format = tap.format {
            print("tap format  \(Int(format.mSampleRate)) Hz · \(format.mChannelsPerFrame)ch")
        } else {
            print("tap format  not published")
        }

        // A tap only becomes readable once it is a member of a running
        // aggregate, so build one to prove the whole chain, not just creation.
        guard let output = try AudioDevices.device(uid: "YunAudioDevice_UID") else {
            print("YunAudio driver not installed; skipping aggregate check")
            exit(0)
        }
        // Route the tap's stereo pair into the virtual device and watch the
        // meters: proof that an application's audio is reachable as a routing
        // source, not merely that a tap object can be created.
        guard let mic = try AudioDevices.defaultInput() else {
            print("no default input to act as clock master")
            exit(1)
        }
        let engine = RoutingEngine()
        let tapRoutes = (0..<2).map { channel in
            Route(
                source: ChannelRef(deviceUID: tap.uid, channel: channel),
                destination: ChannelRef(deviceUID: output.uid, channel: channel))
        }
        try engine.start(
            sourceDeviceUID: mic.uid,
            destinationDeviceUID: output.uid,
            routes: tapRoutes,
            taps: [tap])
        print("\nrouting \(match) → \(output.name) for 4s — play something in it\n")
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.33)
            let bars = engine.routePeaks.map { peak -> String in
                let db = peak > 0 ? 20 * log10(peak) : -120
                let filled = max(0, min(20, Int((db + 60) / 3)))
                return String(repeating: "█", count: filled)
                    + String(repeating: "·", count: 20 - filled)
            }
            print("  \(bars.joined(separator: "  "))")
        }
        engine.stop()
    } catch {
        print("tap failed: \(error)")
        exit(1)
    }
    exit(0)
}

// A tappable noise source, for verifying capture paths against a known signal.
//
// `afplay` looks like the obvious tool and is not: it never appears in
// `kAudioHardwarePropertyProcessObjectList`, because it hands its audio to a
// system process rather than opening a client of its own, so there is nothing
// to tap. An AVAudioEngine playing into the default output does register, which
// is what makes it usable as a fixture.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "tone" {
    let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 10 : 10
    let frequency =
        CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 440 : 440

    let engine = AVAudioEngine()
    let output = engine.outputNode
    let rate = output.inputFormat(forBus: 0).sampleRate
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
        print("could not build a format")
        exit(1)
    }

    // The phase lives in a box and the closure is `@Sendable`, both for the same
    // reason: top-level code in Swift 6 is main-actor isolated, so a render
    // block that closes over a local `var` inherits that isolation and asserts
    // it is running on the main queue. The audio thread is not the main queue,
    // and the assertion is a SIGTRAP rather than a warning.
    let phase = TonePhase()
    let increment = 2 * Double.pi * frequency / rate
    let source = AVAudioSourceNode(format: format) {
        @Sendable _, _, frameCount, audioBufferList in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<Int(frameCount) {
            let value = Float(sin(phase.value) * 0.2)
            phase.value += increment
            if phase.value > 2 * .pi { phase.value -= 2 * .pi }
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
            }
        }
        return noErr
    }

    engine.attach(source)
    engine.connect(source, to: output, format: format)
    do {
        try engine.start()
    } catch {
        print("could not start: \(error)")
        exit(1)
    }
    print("pid \(ProcessInfo.processInfo.processIdentifier)")
    print("playing \(Int(frequency)) Hz for \(seconds)s at \(Int(rate)) Hz")
    fflush(stdout)
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
    exit(0)
}

// Proves an application's own audio reaches the canceller's far-end input.
//
// The tap goes into an aggregate of its own and an IOProc pushes it into a
// lock-free ring; this drains that ring from the other side, exactly as the
// voice processing unit's render callback will. What it checks is the thing
// that cannot be checked by inspection: that real frames, at a real level,
// actually cross between the two threads.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "far-end" {
    let match = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Discord"
    let seconds = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 6 : 6

    guard let applications = try? AudioApplications.grouped() else {
        print("could not enumerate applications")
        exit(1)
    }
    // Fall back to the raw process list. Anything without a bundle identifier
    // is not offered in the interface — capture is keyed on that identifier —
    // but `afplay` and its kind are exactly what one reaches for to put a known
    // signal through this path, so the command should be able to name them.
    let target: (name: String, ids: [AudioObjectID], count: Int)
    if let application = applications.first(where: {
        $0.name.localizedCaseInsensitiveContains(match)
            || $0.bundleID.localizedCaseInsensitiveContains(match)
    }) {
        target = (application.name, application.processIDs, application.processCount)
    } else {
        // A bare executable has no bundle identifier and no entry in the
        // running-application list, so it has no name to match on — a process
        // id is the only handle it has.
        let wantedPID = pid_t(match)
        let processes = ((try? AudioProcesses.all(includingSilent: true)) ?? [])
            .filter {
                if let wantedPID { return $0.pid == wantedPID }
                return $0.name.localizedCaseInsensitiveContains(match)
                    || ($0.bundleID?.localizedCaseInsensitiveContains(match) ?? false)
            }
        guard !processes.isEmpty else {
            print("nothing matching \"\(match)\" is producing audio")
            exit(1)
        }
        target = (processes[0].name, processes.map(\.id), processes.count)
    }

    // Unmuted: this is a measurement, and silencing the application would
    // remove the very thing being measured from the speakers as well.
    guard
        let capture = FarEndCapture(
            processIDs: target.ids, muteBehavior: .unmuted)
    else {
        print("could not build the far-end capture")
        exit(1)
    }

    print(
        """
        far end  \(target.name)  ·  \(target.count) process(es)
        format   \(Int(capture.sampleRate)) Hz · \(capture.sourceChannels)ch → mono

        """)
    guard capture.start() else {
        print("the capture would not start")
        exit(1)
    }

    let block = 1024
    var buffer = [Float](repeating: 0, count: block)
    var totalRead = 0
    var peak: Float = 0
    var energy: Double = 0

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let frames = buffer.withUnsafeMutableBufferPointer {
            capture.read(into: $0.baseAddress!, frames: block)
        }
        if frames == 0 {
            usleep(5000)
            continue
        }
        totalRead += frames
        for index in 0..<frames {
            let value = buffer[index]
            peak = max(peak, abs(value))
            energy += Double(value) * Double(value)
        }
    }
    capture.stop()

    let decibels = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    let rms = totalRead > 0 ? (energy / Double(totalRead)).squareRoot() : 0
    let rmsDecibels = rms > 0 ? 20 * log10(rms) : -.infinity

    print("produced  \(capture.producedFrames) frames")
    print("drained   \(totalRead) frames")
    print("buffered  \(capture.bufferedFrames) frames still in the ring")
    print("dropped   \(capture.droppedFrames) frames")
    print(String(format: "peak      %.1f dBFS", decibels))
    print(String(format: "rms       %.1f dBFS", rmsDecibels))

    if totalRead == 0 {
        print("\nnothing crossed the ring — is the application producing audio?")
        exit(1)
    }
    if peak == 0 {
        print("\nframes crossed but every one was silent")
        exit(1)
    }
    // The distinction that matters is not tone versus music — it is that the
    // signal came out of another process through a tap and across a ring,
    // rather than being synthesised inside the canceller where nothing can go
    // wrong with it.
    print("\nthe reference is another process's audio, carried across the ring")
    exit(0)
}

// Measures how much echo the canceller actually removes.
//
// A tone is played through the speaker and the microphone level is measured
// twice over the same acoustic path — once with voice processing active, once
// bypassed. Everything but the canceller is identical between the two, so the
// difference is the cancellation.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "aec-measure" {
    let all = (try? AudioDevices.all()) ?? []
    guard let mic = all.first(where: { $0.name.contains("MacBook") && $0.hasInput }),
        let speaker = all.first(where: { $0.name.contains("MacBook") && $0.hasOutput })
    else { print("need the built-in microphone and speakers"); exit(1) }

    guard
        let capture = EchoCancellingCapture(
            microphoneUID: mic.uid, speakerUID: speaker.uid)
    else { print("could not set up the unit"); exit(1) }

    // Accumulators are touched by the audio thread and the main thread, so they
    // go behind a lock. Without one, Swift's exclusivity checking traps the
    // process the moment both threads reach the same property — which is
    // exactly what happened the first time this was written.
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        var phase: Float = 0  // audio thread only
        private var sum: Double = 0
        private var count: Int = 0
        private var measuring = false

        func beginMeasuring() {
            lock.lock(); defer { lock.unlock() }
            sum = 0; count = 0; measuring = true
        }

        func endMeasuring() -> (sum: Double, count: Int) {
            lock.lock(); defer { lock.unlock() }
            measuring = false
            return (sum, count)
        }

        func accumulate(_ energy: Double, frames: Int) {
            lock.lock(); defer { lock.unlock() }
            guard measuring else { return }
            sum += energy
            count += frames
        }
    }
    let state = State()
    let rate = Float(capture.sampleRate)

    // A quiet 440 Hz tone. Loud enough to be picked up by a microphone a few
    // centimetres away, quiet enough not to be unpleasant.
    let amplitude: Float = 0.1
    let increment = 2 * Float.pi * 440 / rate

    _ = capture.start(
        capture: { samples, count, _ in
            var energy: Double = 0
            for index in 0..<count {
                let value = Double(samples[index])
                energy += value * value
            }
            state.accumulate(energy, frames: count)
        },
        farEnd: { buffer, frames in
            for index in 0..<frames {
                buffer[index] = sin(state.phase) * amplitude
                state.phase += increment
                if state.phase > 2 * .pi { state.phase -= 2 * .pi }
            }
            return frames
        })

    func measure(bypassed: Bool, label: String) -> Double {
        capture.setBypassed(bypassed)
        Thread.sleep(forTimeInterval: 0.8)  // let the canceller settle
        state.beginMeasuring()
        Thread.sleep(forTimeInterval: 2.0)
        let (sum, count) = state.endMeasuring()
        guard count > 0 else { return -120 }
        let rms = (sum / Double(count)).squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -120
        print(String(format: "  %@  %.1f dBFS RMS", label, db))
        return db
    }

    print("playing a quiet 440 Hz tone through \(speaker.name)")
    print("measuring \(mic.name)\n")
    let bypassed = measure(bypassed: true, label: "processing bypassed")
    let processed = measure(bypassed: false, label: "processing active   ")
    capture.stop()

    let reduction = bypassed - processed
    print(String(format: "\n  echo reduction: %.1f dB", reduction))
    if reduction > 6 {
        print("  the canceller is removing the speaker signal from the microphone")
    } else if reduction > 0 {
        print("  some reduction, but less than a canceller should manage")
    } else {
        print("  no measurable reduction — the far end is not reaching the canceller")
    }
    exit(0)
}

// Runs echo-cancelled capture against a real microphone/speaker pair.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "aec-run" {
    let micMatch =
        CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "MacBook Pro的麥克風"
    let speakerMatch =
        CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "MacBook Pro的揚聲器"
    let all = (try? AudioDevices.all()) ?? []
    guard let mic = all.first(where: { $0.name.contains(micMatch) && $0.hasInput }),
        let speaker = all.first(where: { $0.name.contains(speakerMatch) && $0.hasOutput })
    else {
        print("could not find both \"\(micMatch)\" and \"\(speakerMatch)\"")
        exit(1)
    }
    print("microphone  \(mic.name)  (\(mic.inputChannels) in / \(mic.outputChannels) out)")
    print("speaker     \(speaker.name)")

    guard
        let capture = EchoCancellingCapture(
            microphoneUID: mic.uid, speakerUID: speaker.uid)
    else {
        print("AUVoiceProcessingIO could not be set up for that pair")
        exit(1)
    }
    print(
        "bound to    \(capture.isBoundToDedicatedDevice ? "a private aggregate" : "the system defaults")"
    )
    print("rate        \(Int(capture.sampleRate)) Hz")

    // Peak is published through an atomic-free box read on the main thread; a
    // torn float would cost one stale meter frame and nothing else.
    final class Meter: @unchecked Sendable {
        var peak: Float = 0
        var frames = 0
    }
    let meter = Meter()

    guard
        capture.start(capture: { samples, count, _ in
            var peak: Float = 0
            for index in 0..<count {
                let magnitude = abs(samples[index])
                if magnitude > peak { peak = magnitude }
            }
            meter.peak = max(meter.peak * 0.8, peak)
            meter.frames += count
        })
    else {
        print("could not start the unit")
        exit(1)
    }

    print("\ncapturing echo-cancelled microphone for 5s — speak\n")
    for _ in 0..<15 {
        Thread.sleep(forTimeInterval: 0.33)
        let db = meter.peak > 0 ? 20 * log10(meter.peak) : -120
        let filled = max(0, min(24, Int((db + 60) / 2.5)))
        print(
            "  \(String(repeating: "█", count: filled))\(String(repeating: "·", count: 24 - filled))  \(meter.frames) frames"
        )
    }
    capture.stop()
    print("\ntotal frames captured: \(meter.frames)")
    exit(meter.frames > 0 ? 0 : 1)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "aec" {
    // Three configurations, because the interesting question is not "does it
    // work" but "which binding does it accept".
    print("— system defaults (no device set) —")
    print(EchoCancellation.probe(inputDeviceUID: nil).summary)

    let devices = (try? AudioDevices.all()) ?? []
    for device in devices where device.hasInput {
        let duplex = device.hasOutput ? "duplex" : "input-only"
        print("\n— \(device.name)  (\(duplex)) —")
        print(EchoCancellation.probe(inputDeviceUID: device.uid).summary)
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "dsp" {
    for frames in [64, 128, 256, 512] {
        print(SoundIsolation.probe(sampleRate: 48000, blockFrames: frames).summary)
        print("")
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "selftest" {
    let source = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Seiren V3 Pro"
    let destination = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "YunAudio"
    do {
        try runSelftest(sourceMatch: source, destinationMatch: destination)
    } catch {
        print("selftest failed: \(error)")
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "route" {
    let source = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Seiren V3 Pro"
    let destination = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "BlackHole"
    let seconds =
        CommandLine.arguments.count > 4
        ? Double(CommandLine.arguments[4]) ?? 5 : 5
    let isolation = CommandLine.arguments.contains("--isolate")
    do {
        try runRoute(
            sourceMatch: source, destinationMatch: destination, seconds: seconds,
            voiceIsolation: isolation)
    } catch {
        print("route failed: \(error)")
        exit(1)
    }
    exit(0)
}

do {
    let devices = try AudioDevices.all()
    let defaultInput = try AudioDevices.defaultInput()
    let defaultOutput = try AudioDevices.defaultOutput()

    print("YunAudio HAL probe — \(devices.count) devices")
    print(String(repeating: "=", count: 60))

    for device in devices {
        describe(
            device,
            isDefaultInput: device.id == defaultInput?.id,
            isDefaultOutput: device.id == defaultOutput?.id)
    }

    // Clock relationships between every input-capable and output-capable pair.
    // This is what the UI's path-quality badge will report.
    print("\n" + String(repeating: "=", count: 60))
    print("clock relationships (input source → output destination)\n")
    let sources = devices.filter(\.hasInput)
    let destinations = devices.filter(\.hasOutput)
    for source in sources {
        for destination in destinations where source.id != destination.id {
            let relationship = source.clockRelationship(to: destination)
            let verdict =
                switch relationship {
                case .sameDomain: "bit-exact"
                case .differentDomains: "resampled (drift correction)"
                case .unknown: "assume resampled (domain not published)"
                }
            print("  \(source.name) → \(destination.name): \(verdict)")
        }
    }
} catch {
    print("probe failed: \(error)")
    exit(1)
}

/// The tone generator's oscillator phase.
///
/// `@unchecked Sendable` because only the audio thread ever touches it: the
/// main thread creates it, hands it over and then sleeps.
final class TonePhase: @unchecked Sendable {
    var value = 0.0
}
