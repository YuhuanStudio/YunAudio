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
    print("  sample rate  \(Int(device.nominalSampleRate)) Hz  (available: \(rateList(device.availableSampleRates)))")

    // Domains are four-char codes; 'main' is the Mac's own audio clock, which
    // built-in and synchronous USB devices slave to. A device with its own
    // crystal (asynchronous USB) publishes nothing.
    let domain = device.clockDomain.map { "\(fourCharDescription($0)) (\($0))" } ?? "not published"
    print("  clock domain \(domain)")

    if let frames = device.currentBufferFrameSize {
        let ms = device.nominalSampleRate > 0
            ? String(format: " (%.2f ms)", Double(frames) / device.nominalSampleRate * 1000) : ""
        print("  buffer       \(frames) frames\(ms)")
    }

    if device.hasInput {
        let frames = device.latencyFrames(scope: kAudioObjectPropertyScopeInput)
        let ms = device.nominalSampleRate > 0
            ? String(format: " (%.2f ms)", Double(frames) / device.nominalSampleRate * 1000) : ""
        print("  in latency   \(frames) frames\(ms)")
    }
    if device.hasOutput {
        let frames = device.latencyFrames(scope: kAudioObjectPropertyScopeOutput)
        let ms = device.nominalSampleRate > 0
            ? String(format: " (%.2f ms)", Double(frames) / device.nominalSampleRate * 1000) : ""
        print("  out latency  \(frames) frames\(ms)")
    }

    let inputStreams = device.inputStreams
    if !inputStreams.isEmpty {
        print("  input streams")
        for stream in inputStreams {
            let current = stream.currentPhysicalFormat.map(String.init(describing:)) ?? "—"
            print("    · stream \(stream.id) starting at ch \(stream.startingChannel): \(current)")
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
    guard let source = devices.first(where: { $0.name.contains(sourceMatch) && $0.hasInput }) else {
        print("no input device matching \"\(sourceMatch)\"")
        exit(1)
    }
    guard let destination = devices.first(where: {
        $0.name.contains(destinationMatch) && $0.hasOutput
    }) else {
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
    print("routes      \(signalRoutes.map { "ch\($0.source.channel + 1)→ch\($0.destination.channel + 1)" }.joined(separator: ", "))")

    // BlackHole is a loopback: whatever is written to its output reappears on
    // its input. Since it is already a member of the aggregate, reading its
    // input in the same IOProc proves the signal actually landed there rather
    // than merely being read off the microphone. Gain 0 keeps this route
    // silent — peaks are metered pre-gain, so it is a pure probe.
    var allRoutes = signalRoutes
    let probeChannel = destination.outputChannels - 1
    if destination.inputChannels > 0 {
        allRoutes.append(Route(
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
        print(String(
            format: "buffer      %d frames (%.2f ms)",
            quality.bufferFrames, quality.bufferLatencyMilliseconds))
        print("path        \(quality.isBitExact ? "bit-exact" : "resampled — drift correction on \(quality.driftCorrectedDeviceUIDs.joined(separator: ", "))")")
    }
    if let publisher = ClockAnchorPublisher(), publisher.driverSupportsClockLocking {
        print("clock       YunAudio driver supports clock locking")
    } else {
        print("clock       destination cannot be clock-locked (not the YunAudio driver, or it predates clock anchors)")
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
        let lock = engine.isClockLocked
            ? String(format: "LOCKED %.6f", engine.measuredRateRatio) : "unlocked"
        print("  cycles +\(delta)  \(bars.joined(separator: "  "))  \(lock)")
    }

    // Re-read after the run: the clock lock takes about a second and a half to
    // converge, so the verdict printed at startup is always the pessimistic one.
    if let quality = engine.pathQuality {
        print("")
        if quality.isBitExact {
            print(String(
                format: "path        bit-exact — no resampling configured, clock locked at %.6f",
                engine.measuredRateRatio))
            print("            (configuration-level claim; --selftest is the sample-level proof)")
        } else if quality.hasProcessing {
            print("path        processed — voice isolation is altering the signal by design")
        } else if quality.driftCorrectedDeviceUIDs.isEmpty {
            print("path        no drift correction configured, but the clock lock is not holding")
        } else {
            print("path        resampled — drift correction on "
                + quality.driftCorrectedDeviceUIDs.joined(separator: ", "))
        }
    }

    engine.stop()
    let violations = RoutingEngine.allocationViolations - violationsBefore
    print("stopped. total IO cycles: \(lastCycle)")
    print(String(
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
        print("need an input device matching \"\(sourceMatch)\" and a loopback-capable output matching \"\(destinationMatch)\"")
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
        print("drift correction  "
            + (quality.driftCorrectedDeviceUIDs.isEmpty
                ? "none" : quality.driftCorrectedDeviceUIDs.joined(separator: ", ")))
    }

    print("\ncapturing…")
    while engine.selftestProgress < 1.0 {
        Thread.sleep(forTimeInterval: 0.25)
        print(String(format: "  %.0f%%  %@", engine.selftestProgress * 100,
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
        print("realtime path: \(violations) ALLOCATIONS on the IO thread — the no-allocation rule is broken")
    }
    exit(result.isBitExact && violations == 0 ? 0 : 1)
}

// MARK: - Run

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
        print("  vendor pages " + device.vendorUsagePages
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
        let processes = try AudioProcesses.all()
        print("tappable processes — \(processes.count)\n")
        for process in processes {
            let marker = process.isPlaying ? "▶" : " "
            print("  \(marker) \(process.name)  ·  pid \(process.pid)  ·  \(process.bundleID ?? "—")")
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
            print("  · \(process.name)  pid \(process.pid)\(process.isPlaying ? "  [playing]" : "")")
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
    let seconds = CommandLine.arguments.count > 4
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
            let verdict = switch relationship {
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
