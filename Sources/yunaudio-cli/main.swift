import AVFoundation
import CoreAudio
import Darwin
import Foundation
import YunAudioControl
import YunAudioEngine
import YunAudioHAL
import YunAudioRazer

// A verification harness for the HAL layer. Everything the GUI will rely on is
// readable here first, so device quirks surface before any UI exists.

private struct IndependentInputCadence {
    var callbacks: UInt64 = 0
    var silentCallbacks: UInt64 = 0
    var firstHostTime: UInt64 = 0
    var lastHostTime: UInt64 = 0
    var longestGap: UInt64 = 0
    var peak: Float = 0
}

private struct IndependentInputCapture {
    var channelCount: Int
    var capacityFrames: Int
    var capturedFrames: Int = 0
    var callbacks: UInt64 = 0
    var malformedCallbacks: UInt64 = 0
    var samples: UnsafeMutablePointer<Float>
}

/// Copies every physical input channel into preallocated planar storage.
///
/// There is one producer and the main thread reads only after
/// `AudioDeviceStop` returns. The callback therefore needs neither an atomic
/// nor a lock, and it performs no allocation, logging or Objective-C work.
private let independentInputCaptureIOProc: AudioDeviceIOProc = {
    _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let capture = clientData.assumingMemoryBound(to: IndependentInputCapture.self)
    let buffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData))

    var reportedChannels = 0
    var cycleFrames = Int.max
    for buffer in buffers {
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { continue }
        reportedChannels += channels
        cycleFrames = min(
            cycleFrames,
            Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
    }
    guard reportedChannels == capture.pointee.channelCount, cycleFrames != Int.max,
        cycleFrames > 0
    else {
        capture.pointee.malformedCallbacks &+= 1
        return noErr
    }

    let available = capture.pointee.capacityFrames - capture.pointee.capturedFrames
    let frames = min(cycleFrames, max(0, available))
    guard frames > 0 else { return noErr }
    let destinationStart = capture.pointee.capturedFrames
    var absoluteChannel = 0
    for buffer in buffers {
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0, let data = buffer.mData else {
            absoluteChannel += channels
            continue
        }
        let source = data.assumingMemoryBound(to: Float.self)
        for localChannel in 0..<channels {
            let destination =
                capture.pointee.samples
                + (absoluteChannel + localChannel) * capture.pointee.capacityFrames
                + destinationStart
            for frame in 0..<frames {
                destination[frame] = source[frame * channels + localChannel]
            }
        }
        absoluteChannel += channels
    }
    capture.pointee.capturedFrames += frames
    capture.pointee.callbacks &+= 1
    return noErr
}

// A C IOProc rather than a Swift block. Swift 6 correctly traps when a block
// inherited from the main actor is called on CoreAudio's realtime queue; the
// measuring tool must obey the same isolation and realtime rules as the app.
private let independentInputIOProc: AudioDeviceIOProc = {
    _, now, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let cadence = clientData.assumingMemoryBound(to: IndependentInputCadence.self)
    let hostTime =
        now.pointee.mFlags.contains(.hostTimeValid)
        ? now.pointee.mHostTime : mach_absolute_time()
    if cadence.pointee.lastHostTime > 0 {
        cadence.pointee.longestGap = max(
            cadence.pointee.longestGap, hostTime - cadence.pointee.lastHostTime)
    } else {
        cadence.pointee.firstHostTime = hostTime
    }
    cadence.pointee.lastHostTime = hostTime
    cadence.pointee.callbacks += 1

    let buffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData))
    var cyclePeak: Float = 0
    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        for index in 0..<count {
            cyclePeak = max(cyclePeak, abs(samples[index]))
        }
    }
    cadence.pointee.peak = max(cadence.pointee.peak, cyclePeak)
    if cyclePeak <= 0.000_000_1 { cadence.pointee.silentCallbacks += 1 }
    return noErr
}

func transportLabel(_ transport: AudioTransport) -> String {
    switch transport {
    case .builtIn: "built-in"
    case .usb: "USB"
    case .thunderbolt: "Thunderbolt"
    case .hdmi: "HDMI"
    case .displayPort: "DisplayPort"
    case .bluetooth: "Bluetooth"
    // Named apart because it is the one that does not lose its output quality
    // to carrying a microphone.
    case .bluetoothLE: "Bluetooth LE Audio"
    case .airPlay: "AirPlay"
    case .virtual: "virtual"
    case .aggregate: "aggregate"
    case .pci: "PCI"
    case .fireWire: "FireWire"
    case .avb: "AVB"
    case .continuityCapture: "Continuity Capture"
    case let .other(raw): "other \(fourCharDescription(raw))"
    case .unknown: "unknown"
    }
}

/// A clock master automation may open without waking a nearby phone or tablet.
func automaticPhysicalInput(in devices: [AudioDevice]) -> AudioDevice? {
    devices.first {
        $0.hasInput && !$0.transport.isVirtual
            && !$0.transport.requiresExplicitInputSelection
    }
}

private final class SpeechPlaybackState: @unchecked Sendable {
    private let lock = NSLock()
    private var finishedValue = false
    private var scheduledValue = 0
    private var completedValue = 0

    func scheduled() {
        lock.lock()
        scheduledValue += 1
        lock.unlock()
    }

    func finished() {
        lock.lock()
        finishedValue = true
        lock.unlock()
    }

    func completed() {
        lock.lock()
        completedValue += 1
        lock.unlock()
    }

    var snapshot: (finished: Bool, scheduled: Int, completed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (finishedValue, scheduledValue, completedValue)
    }
}

/// Plays deterministic synthesised speech into one device without changing the
/// system default output. It is a fixture for the same voice-processing chain
/// a microphone uses, with a repeatable signal instead of somebody having to
/// speak at exactly the right time.
private func playSyntheticSpeech(deviceMatch: String) -> Bool {
    guard
        let device = (try? AudioDevices.all())?.first(where: {
            $0.hasOutput && $0.name.localizedCaseInsensitiveContains(deviceMatch)
        })
    else {
        print("no output device matched \(deviceMatch)")
        return false
    }

    let engine = AVAudioEngine()
    let output = engine.outputNode
    var target = device.id
    let status = AudioUnitSetProperty(
        output.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else {
        print("could not select \(device.name): \(fourCharDescription(status))")
        return false
    }

    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    do { try engine.start() } catch {
        print("could not start speech output: \(error)")
        return false
    }
    defer { engine.stop() }

    let state = SpeechPlaybackState()
    let synthesiser = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(
        string:
            "Discord should receive every word of this sentence without gaps. "
            + "The quick brown fox jumps over the lazy dog, then says the sentence again. "
            + "Discord should receive every word of this sentence without gaps.")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesiser.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            state.finished()
            return
        }
        guard let converted = convert(pcm, to: engine.mainMixerNode.outputFormat(forBus: 0))
        else {
            state.finished()
            return
        }
        player.scheduleBuffer(converted) { state.completed() }
        state.scheduled()
        if !player.isPlaying { player.play() }
    }

    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline {
        let snapshot = state.snapshot
        if snapshot.finished, snapshot.completed >= snapshot.scheduled {
            player.stop()
            print("played \(snapshot.scheduled) speech buffers into \(device.name)")
            return snapshot.scheduled > 0
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let snapshot = state.snapshot
    print("speech fixture timed out after \(snapshot.scheduled) buffers")
    return false
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

    // What the channels carry, where the device's topology is known. CoreAudio
    // will not say, and on the Seiren V3 Pro the three inputs are three
    // different versions of the same capsule.
    //
    // Only for a device that has inputs. A profile is matched on a name, and
    // the Barracuda publishes the same name twice — so the output half of the
    // headset was listing an input channel it does not have.
    if device.hasInput,
        let named = DeviceChannelNames.channels(
            modelUID: device.modelUID, name: device.name,
            scope: kAudioObjectPropertyScopeInput)
    {
        print("  input channels")
        for (index, channel) in named.enumerated() {
            let marker = channel.isDefault ? " ←" : ""
            print("    ch \(index + 1)  \(channel.name)\(marker)")
        }
    }

    // The rest of what the profile knows. It was written down and then reachable
    // only from the tests — which is a strange place to keep the one sentence
    // that explains why somebody's headset records at 16 kHz.
    if let note = DeviceChannelNames.note(modelUID: device.modelUID, name: device.name) {
        print("  known about this device")
        for line in wrapped(note, width: 74) { print("    \(line)") }
    }
}

/// Breaks prose at spaces so a paragraph in a device profile does not print as
/// one line four hundred characters wide.
func wrapped(_ text: String, width: Int) -> [String] {
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
        if line.isEmpty {
            line = String(word)
        } else if line.count + 1 + word.count <= width {
            line += " " + word
        } else {
            lines.append(line)
            line = String(word)
        }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

// MARK: - Route mode

/// Brings up a real route and reports what the engine sees, so the audio path
/// can be verified before any UI exists.
func runRoute(
    sourceMatch: String, destinationMatch: String, seconds: Double,
    voiceIsolation: Bool = false, effects: [EffectKind] = [], bufferFrames: UInt32 = 128,
    preferredSampleRate: Double? = nil, sourceChannel: Int? = nil
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

    let signalRoutes: [Route]
    if let sourceChannel {
        guard sourceChannel >= 0, sourceChannel < source.inputChannels else {
            print(
                "source channel \(sourceChannel + 1) is outside 1…\(source.inputChannels)")
            exit(1)
        }
        signalRoutes = (0..<min(2, destination.outputChannels)).map { destinationChannel in
            Route(
                source: ChannelRef(deviceUID: source.uid, channel: sourceChannel),
                destination: ChannelRef(
                    deviceUID: destination.uid, channel: destinationChannel))
        }
    } else {
        let pairs = min(2, min(source.inputChannels, destination.outputChannels))
        signalRoutes = (0..<pairs).map { channel in
            Route(
                source: ChannelRef(deviceUID: source.uid, channel: channel),
                destination: ChannelRef(deviceUID: destination.uid, channel: channel))
        }
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
        effects: effects,
        preferredSampleRate: preferredSampleRate,
        bufferFrames: bufferFrames,
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
    // Core Audio's own name for the gap somebody hears. Reported per interval
    // rather than only as a total, because the line it lands on carries the
    // peaks and the clock state at that instant — which is the whole reason to
    // record a dropout rather than remember one.
    var lastOverloads = engine.ioProcOverloadCount
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
        let sourcePeak = peaks.max() ?? 0
        let outputPeak = engine.outputPeak
        let sourceDB = sourcePeak > 0 ? 20 * log10(sourcePeak) : -.infinity
        let outputDB = outputPeak > 0 ? 20 * log10(outputPeak) : -.infinity
        let overloads = engine.ioProcOverloadCount
        let missed = overloads - lastOverloads
        lastOverloads = overloads
        print(
            String(
                format: "  cycles +%llu  source %7.1f dBFS  output %7.1f dBFS  %@  %@%@",
                delta, sourceDB, outputDB, bars.joined(separator: "  "), lock,
                missed > 0 ? "  ** \(missed) MISSED DEADLINE\(missed == 1 ? "" : "S")" : ""))
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

    // Read before the teardown, not after.
    //
    // The first run of this printed `device 162: 1` — an identifier with no
    // name, because the device that missed the deadline was the aggregate this
    // route had built, and by the time `stop()` returned it no longer existed
    // to be asked its name. The one overload worth naming above all others was
    // the one this could not name.
    let overloadsByDevice = engine.ioProcOverloadsByDevice
    let totalOverloads = engine.ioProcOverloadCount
    let overloadEvents = engine.recentIOProcOverloads
    let aggregateID = engine.aggregate?.id
    let overloadNames: [AudioObjectID: String] = Dictionary(
        uniqueKeysWithValues: overloadsByDevice.keys.map { device in
            if device == aggregateID { return (device, "the route's own aggregate") }
            return (device, (try? AudioDevice(id: device))?.name ?? "device \(device)")
        })

    engine.stop()
    let violations = RoutingEngine.allocationViolations - violationsBefore
    print("stopped. total IO cycles: \(lastCycle)")
    print(
        String(
            format: "realtime path: %llu allocations over %llu cycles (%.1f per cycle)",
            violations, lastCycle,
            lastCycle > 0 ? Double(violations) / Double(lastCycle) : 0))
    if totalOverloads == 0 {
        print("missed deadlines: none")
    } else {
        print("missed deadlines: \(totalOverloads)")
        // Named per device because they are different faults. The aggregate is
        // the one our IOProc is attached to, so it reports us running late; a
        // member reports an endpoint failing to keep a schedule it agreed to,
        // and only the second is somebody else's problem to fix.
        for (device, count) in overloadsByDevice.sorted(by: { $0.value > $1.value }) {
            print("  \(overloadNames[device] ?? "device \(device)"): \(count)")
        }
        // When, relative to each other. A cluster in the first second is a
        // route settling; one in the middle of a steady run is not, and those
        // are different problems however alike the totals look.
        if let first = overloadEvents.first {
            let offsets = overloadEvents.prefix(12).map {
                String(format: "%.2fs", $0.at - first.at)
            }
            print("  at +\(offsets.joined(separator: ", +")) from the first")
        }
    }
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

    let driverHealthBefore = AudioIncidentDriverHealthReader.read(
        deviceID: destination.id,
        wasRequired: destination.uid == ClockAnchorPublisher.driverDeviceUID,
        until: HALTeardownDeadline(timeout: 0.25))

    let engine = RoutingEngine()
    // A rate can be forced, so that "does this path work at 96 kHz" is a
    // question somebody can put to it rather than a guess about why a
    // particular microphone behaves differently.
    let forcedRate = ProcessInfo.processInfo.environment["YUNAUDIO_RATE"].flatMap(Double.init)
    if let forcedRate { print("forced rate   \(Int(forcedRate)) Hz") }
    try engine.start(
        sourceDeviceUID: source.uid,
        destinationDeviceUID: destination.uid,
        routes: [],
        preferredSampleRate: forcedRate,
        selftest: true)

    if let quality = engine.pathQuality {
        print("rate          \(Int(quality.sampleRate)) Hz")
        print(
            "drift correction  "
                + (quality.driftCorrectedDeviceUIDs.isEmpty
                    ? "none" : quality.driftCorrectedDeviceUIDs.joined(separator: ", ")))
    }

    print("\ncapturing…")
    let filled = engine.awaitSelftest { progress in
        print(
            String(
                format: "  %.0f%%  %@", progress * 100,
                engine.isClockLocked
                    ? String(format: "clock locked %.6f", engine.measuredRateRatio)
                    : "clock unlocked"))
    }
    guard filled else {
        engine.stop()
        print(
            """

            nothing came back. The destination has no input to read the sequence
            off, so there is no loopback to grade — pick a destination that has
            one (this project's own driver, or any other loopback device).
            """)
        exit(1)
    }

    let result = engine.evaluateSelftest()
    let locked = engine.isClockLocked
    let ratio = engine.measuredRateRatio
    // Stop may hand the driver through a new IO lifetime while the aggregate
    // is dismantled. Read the fault coordinates before that boundary, then use
    // the post-fence counters below for the actual pass/fail decision.
    let liveDriverEvidence = AudioIncidentDriverHealthReader.read(
        deviceID: destination.id,
        wasRequired: destination.uid == ClockAnchorPublisher.driverDeviceUID,
        until: HALTeardownDeadline(timeout: 0.25))
    let teardown = engine.stop()
    let driverHealthAfter = AudioIncidentDriverHealthReader.read(
        deviceID: destination.id,
        wasRequired: destination.uid == ClockAnchorPublisher.driverDeviceUID,
        until: HALTeardownDeadline(timeout: 0.25))

    print("")
    guard let result else {
        print("selftest produced no result")
        exit(1)
    }
    print(result.summary)
    if locked { print(String(format: "clock locked at end at %.6f", ratio)) }

    let driverHealthIsClean: Bool
    switch (driverHealthBefore.state, driverHealthAfter.state) {
    case (.available, .available)
    where driverHealthAfter.unsafeReadOperations >= driverHealthBefore.unsafeReadOperations
        && driverHealthAfter.unsafeWriteOperations
            >= driverHealthBefore.unsafeWriteOperations:
        let unsafeReads =
            driverHealthAfter.unsafeReadOperations - driverHealthBefore.unsafeReadOperations
        let unsafeWrites =
            driverHealthAfter.unsafeWriteOperations - driverHealthBefore.unsafeWriteOperations
        print("driver unsafe operations: \(unsafeReads) read, \(unsafeWrites) write")
        let evidence =
            driverHealthAfter.unsafeReadStartFrame == nil
            ? liveDriverEvidence : driverHealthAfter
        if unsafeReads > 0,
            let readStart = evidence.unsafeReadStartFrame,
            let readFrames = evidence.unsafeReadFrameCount,
            let unavailable = evidence.unsafeReadUnavailableFrame,
            let publishedStart = evidence.lastPublishedStartFrame,
            let publishedFrames = evidence.lastPublishedFrameCount
        {
            print(
                "first unsafe read: \(readStart)+\(readFrames), unavailable \(unavailable), "
                    + "last write \(publishedStart)+\(publishedFrames)")
        }
        driverHealthIsClean = unsafeReads == 0 && unsafeWrites == 0
    default:
        print("driver unsafe operations: unavailable")
        driverHealthIsClean = false
    }
    print("teardown: \(teardown.isComplete ? "complete" : "FAILED — \(teardown)")")

    let violations = RoutingEngine.allocationViolations - violationsBefore
    if violations == 0 {
        print("realtime path: 0 allocations on the IO thread")
    } else {
        print(
            "realtime path: \(violations) ALLOCATIONS on the IO thread — the no-allocation rule is broken"
        )
    }
    exit(
        result.isBitExact && violations == 0 && driverHealthIsClean && teardown.isComplete
            ? 0 : 1)
}

// MARK: - Run

// Restores devices to a sane rate.
//
// Routing has to align sample rates across the devices it binds together, and
// that change persists on the hardware after the tool exits. A tool that
// reconfigures someone's hardware has to be able to put it back.
// What is actually going on right now: live taps, and which devices each
// audio-using process has open.
/// Driving the running application rather than the hardware.
///
/// Everything below this line opens devices and measures them. These verbs open
/// nothing: they ask the copy of YunAudio that already owns the route, over the
/// same vocabulary the URL scheme, the MIDI bindings and the scripting
/// interface all speak. `RemoteCommand` is that vocabulary and there is one of
/// it — a fourth private list of verbs in a command-line tool would be a fourth
/// thing to keep in step, and they do not stay in step.
///
/// First, because a control verb has to win over a measuring one that shares
/// its name. `record` used to capture a few seconds to a file here; it now
/// means the application's recorder, and the capture is `capture`.
if CommandLine.arguments.count > 1 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    // Any verb, not only `script`: what somebody wiring a Stream Deck key wants
    // is the URL for the thing they just typed.
    let printingURL = arguments.contains("--url")
    arguments.removeAll { $0 == "--url" }
    let outcome = ControlArguments.parse(arguments)
    if outcome != .notMine {
        exit(RemoteControl.run(outcome, printingURL: printingURL))
    }
}

// Sends one application's audio to a device of its own, the way SoundSource
// does — and silences the copy the application would otherwise play itself.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "send-app" {
    let appMatch = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Discord"
    let deviceMatch = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "MacBook"
    let all = (try? AudioDevices.all()) ?? []
    guard let clock = automaticPhysicalInput(in: all),
        let target = all.first(where: { $0.name.contains(deviceMatch) && $0.hasOutput })
    else {
        print("need an input to act as clock master and an output to send to")
        exit(1)
    }
    let processes = AudioApplications.matching(
        appMatch,
        in: (try? AudioProcesses.all(includingSilent: true)) ?? [])
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
//
// `capture` rather than `record`, which now means the application's own
// recorder — one word cannot be both "measure this machine for five seconds"
// and "start recording, and tell me you did".
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "capture" {
    let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 5 : 5
    let all = (try? AudioDevices.all()) ?? []
    // Any input will do; the USB microphone is often unplugged.
    guard let source = automaticPhysicalInput(in: all),
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
    let recordingFinalisation = engine.stopRecording()
    engine.stop()
    guard recordingFinalisation.wait(timeout: 1) == .complete else {
        print("recording file writer did not finish before the deadline")
        exit(1)
    }

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
            if engine.awaitSelftest(timeout: 20), let result = engine.evaluateSelftest() {
                verdict =
                    result.isBitExact
                    ? "exact @\(result.delayFrames)" : "MISMATCH"
            } else {
                verdict = "no loopback"
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

// Whether the system's audio server is still opening devices.
//
// There is a state this machine reached on 2026-08-25 that nothing could name:
// `AudioDeviceCreateIOProcID` sent a mach message to coreaudiod and never came
// back, in three unrelated processes, while read-only property calls answered
// instantly the whole time. Every reading in every interface was correct and
// nothing could be opened, and the only way to establish that was to attach a
// sampler to a hung process.
//
// This asks the question in three seconds instead.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "health" {
    // Per device, because the first version of this asked only about the
    // default output, said "opening devices normally", and was wrong: the
    // route that could not start was to a different endpoint. A wedge can
    // belong to one device rather than to the server, and those are opposite
    // diagnoses — one is `sudo killall coreaudiod`, the other is a driver.
    if CommandLine.arguments.contains("--each") {
        let all = (try? AudioDevices.all()) ?? []
        print("opening each device in turn (up to \(Int(AudioServerHealth.budget))s each)\n")
        var wedged: [String] = []
        for device in all where device.hasOutput || device.hasInput {
            let id = device.id
            let verdict = AudioServerHealth.probeOne(device: id)
            let mark: String
            switch verdict {
            case .healthy: mark = "opens"
            case .notOpeningDevices:
                mark = "WEDGED — did not return"; wedged.append(device.name)
            case .notAnswering, .cannotTell: mark = "refused"
            }
            print("  \(device.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(mark)")
        }
        print("")
        if wedged.isEmpty {
            print("every device opened. The server is not the problem.")
            exit(0)
        }
        print("\(wedged.count) device(s) did not return: \(wedged.joined(separator: ", "))")
        print("A wedge on one device is that device's driver; a wedge on all of")
        print("them is the server, and that one needs:")
        print("")
        print("    sudo killall coreaudiod")
        exit(2)
    }
    print("asking Core Audio to open a device (up to \(Int(AudioServerHealth.budget))s)…\n")
    switch AudioServerHealth.check() {
    case .healthy:
        print("Core Audio is opening devices normally.")
        exit(0)
    case .notOpeningDevices:
        print("Core Audio answers property reads and will not open a device.")
        print("")
        print("Something is holding the path that opens devices, and no amount")
        print("of waiting clears it — every process on this machine is affected,")
        print("whether or not it has noticed yet.")
        print("")
        print("Look for a stuck client first. In the one reproduction there is,")
        print("a thread inside an application's echo-canceller construction was")
        print("holding it, and quitting that application cleared it without the")
        print("server being restarted at all — `yunaudio-cli diagnose` names the")
        print("processes holding devices.")
        print("")
        print("If nothing is holding it, or quitting does not help, restarting")
        print("the server does, and needs an administrator:")
        print("")
        print("    sudo killall coreaudiod")
        print("")
        print("Audio comes back on its own a second or two later.")
        exit(2)
    case .notAnswering:
        print("Core Audio did not answer a property read either.")
        print("A machine this far gone cannot be told apart from one that is")
        print("merely overwhelmed, so this says so rather than guessing. If it")
        print("stays this way, the same command applies:")
        print("")
        print("    sudo killall coreaudiod")
        exit(2)
    case .cannotTell:
        print("nothing to probe with — no device carrying an output.")
        exit(1)
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "diagnose" {
    let taps = AudioProcesses.liveTaps()
    print("live process taps: \(taps.count)")
    for tap in taps { print("  · \(tap.uid)  (object \(tap.id))") }

    print("\nprocesses holding audio devices:")
    let devices = (try? AudioDevices.all()) ?? []
    // Uniqued rather than trapped, for the same reason as the engine's own map:
    // a device object ID is not guaranteed unique across a list somebody else
    // assembled, and a diagnostic that crashes is worse than one that repeats
    // a name.
    let byID = Dictionary(
        devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    for process in (try? AudioProcesses.all(includingSilent: true)) ?? [] {
        let inputs = process.devices(scope: kAudioObjectPropertyScopeInput)
        let outputs = process.devices(scope: kAudioObjectPropertyScopeOutput)
        guard !inputs.isEmpty || !outputs.isEmpty else { continue }
        let inNames = inputs.map { byID[$0] ?? "object \($0)" }.joined(separator: ", ")
        let outNames = outputs.map { byID[$0] ?? "object \($0)" }.joined(separator: ", ")
        // With the process identifier, because a name is not an identity.
        //
        // Two copies of the same application are one line here otherwise, and
        // that cost real time: the verification harness runs its own build of
        // this application under the same name, so a diagnostic taken while the
        // gate was running attributed the harness's devices to the copy
        // somebody was using — and produced an hour of hunting an idle leak
        // that was a second instance doing its job.
        print("  \(process.name)  [pid \(process.pid)]")
        if !inputs.isEmpty { print("     in:  \(inNames)") }
        if !outputs.isEmpty { print("     out: \(outNames)") }
    }

    // Aggregates, and whether anybody is holding them.
    //
    // This is the one unexplained observation left in the report that
    // coreaudiod degrades until the machine needs a reboot: an
    // `AVVCAggregateDevice` — the one Core Audio's voice processing builds —
    // standing with no client. Nothing could read that state without a
    // debugger, so "is it accumulating?" could only be answered by rebooting
    // and seeing whether the symptom went away.
    //
    // An aggregate nobody holds is not proof of a leak on its own: an
    // application can leave one configured on purpose, and this application's
    // own aggregates exist for as long as a route does. It is the number that
    // has to be watched over a session, and the point is that it can be.
    let aggregates = devices.filter { $0.transport == .aggregate }
    print("\naggregate devices: \(aggregates.count)")
    var heldIDs = Set<AudioObjectID>()
    for process in (try? AudioProcesses.all(includingSilent: true)) ?? [] {
        heldIDs.formUnion(process.devices(scope: kAudioObjectPropertyScopeInput))
        heldIDs.formUnion(process.devices(scope: kAudioObjectPropertyScopeOutput))
    }
    for aggregate in aggregates {
        let held = heldIDs.contains(aggregate.id)
        print("  \(aggregate.name)  [\(aggregate.uid)] — \(held ? "held" : "NO CLIENT")")
    }
    let orphans = aggregates.filter { !heldIDs.contains($0.id) }
    if !orphans.isEmpty {
        print(
            "  \(orphans.count) aggregate(s) with no client. Worth watching across a "
                + "session: growth here is the shape of the reported degradation.")
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
                !device.transport.requiresExplicitInputSelection,
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
        let matches = AudioApplications.matching(match, in: processes)
        guard !matches.isEmpty else {
            print("no process matching \"\(match)\"")
            exit(1)
        }
        print("tapping \(matches.count) process(es):")
        for process in matches {
            let name = AudioApplications.displayName(of: process)
            print("  · \(name)  pid \(process.pid)\(process.isPlaying ? "  [playing]" : "")")
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
        guard let mic = automaticPhysicalInput(in: (try? AudioDevices.all()) ?? []) else {
            print("no local input to act as clock master")
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

// Does the HAL actually keep `processRestoreEnabled` and `bundleIDs`?
//
// macOS 26 added both, and together they are the answer to OBS's issue #9144 —
// "Application Capture loses audio when application reopens on macOS", open
// since June 2023, whose workaround in OBS is a button labelled "Restart
// capture". This project can set them; what this verb answers is whether
// setting them means anything.
//
// It asks the *tap object* rather than the description that was handed over,
// because those are two different things and this project has been caught by
// the difference before: `kAudioSubDeviceInputChannelsKey` reads like a
// constraint and is ignored. A field that is set, accepted and dropped looks
// exactly like a field that works.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "tap-restore" {
    let match = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Music"
    do {
        let processes = try AudioProcesses.all(includingSilent: true)
        let matches = AudioApplications.matching(match, in: processes)
        let bundleIDs = Set(matches.compactMap(\.bundleID)).sorted()
        print("matched \(matches.count) process(es) for \"\(match)\"")
        for process in matches {
            print(
                "  · \(AudioApplications.displayName(of: process))  pid \(process.pid)"
                    + "  \(process.bundleID ?? "no bundle id")")
        }
        guard !bundleIDs.isEmpty else {
            print(
                "\nno bundle identifier to restore by — pick an application, "
                    + "not a helper process")
            exit(1)
        }

        let tap = try ProcessTap(
            processIDs: matches.map(\.id), muteBehavior: .unmuted, bundleIDs: bundleIDs)
        print("\ntap uid          \(tap.uid)")
        print("asked to restore \(bundleIDs.joined(separator: ", "))")

        guard let held = tap.systemDescription() else {
            print("the HAL would not give the description back — nothing can be concluded")
            exit(1)
        }
        // Process restore is macOS 26. Below that there is nothing to check
        // and saying so beats printing an empty list as though the HAL had
        // dropped something.
        guard #available(macOS 26.0, *) else {
            print("process restore needs macOS 26 — nothing to round-trip here")
            exit(0)
        }
        let keptBundles = held.bundleIDs.sorted()
        print("HAL kept restore \(held.isProcessRestoreEnabled)")
        print(
            "HAL kept bundles "
                + (keptBundles.isEmpty ? "—" : keptBundles.joined(separator: ", ")))
        print("HAL kept private \(held.isPrivate)")

        var failures = 0
        // The flag on its own proves nothing: it defaults to true, so every tap
        // this application has ever made already had it on and restored nothing.
        // The bundle identifiers are the half that does the work.
        if !held.isProcessRestoreEnabled {
            print("\n✗ processRestoreEnabled did not survive the round trip")
            failures += 1
        }
        if keptBundles != bundleIDs {
            print("\n✗ bundleIDs came back as \(keptBundles), not \(bundleIDs)")
            failures += 1
        }
        if failures == 0 { print("\n✓ the HAL kept both.") }

        // The round trip proves the HAL *stored* the setting. It does not prove
        // the behaviour, and those are different claims: what somebody wants to
        // know is whether the audio comes back. That needs an application quit
        // and relaunched, which is somebody's own application on somebody's own
        // machine, so it is asked for rather than done.
        if CommandLine.arguments.contains("--watch") {
            let before = held.processes
            print("\nwatching. Quit \(match) and launch it again.")
            print("  processes now: \(before.count)")
            var sawItGo = false
            var restored = false
            for _ in 0..<120 {
                Thread.sleep(forTimeInterval: 0.5)
                guard let now = ProcessTap.description(of: tap.id) else { continue }
                let count = now.processes.count
                if count < before.count { sawItGo = true }
                if sawItGo, count >= before.count {
                    restored = true
                    print("  processes back: \(count)")
                    break
                }
            }
            if restored {
                print("\n✓ the tap reattached on its own. OBS's #9144, not reproduced.")
            } else if sawItGo {
                print("\n✗ the application went away and the tap did not get it back")
                failures += 1
            } else {
                print("\n· nothing quit within a minute, so nothing was learnt")
            }
        } else {
            print("  For the behaviour rather than the setting:")
            print("    yunaudio-cli tap-restore \(match) --watch")
        }
        exit(failures == 0 ? 0 : 1)
    } catch {
        print("tap-restore failed: \(error)")
        exit(1)
    }
}

// Routes with the echo canceller in the path, and reports what crossed.
//
// This is the integration the rest of the echo-cancellation work was building
// towards: the microphone belongs to AUVoiceProcessingIO rather than to the
// router's aggregate, and the cancelled signal reaches the routes across a ring.
// What it checks is that the seam holds — that frames keep arriving at the rate
// the router consumes them, with no standing drift in either direction.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "aec-route" {
    let micMatch =
        CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "MacBook Pro的麥克風"
    let destinationMatch =
        CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "BlackHole"
    let speakerMatch =
        CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "MacBook Pro的揚聲器"
    let seconds = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5]) ?? 8 : 8

    let all = (try? AudioDevices.all()) ?? []
    guard let mic = all.first(where: { $0.name.contains(micMatch) && $0.hasInput }) else {
        print("no input matching \"\(micMatch)\"")
        exit(1)
    }
    guard
        let destination = all.first(where: {
            $0.name.contains(destinationMatch) && $0.hasOutput
        })
    else {
        print("no output matching \"\(destinationMatch)\"")
        exit(1)
    }
    guard let speaker = all.first(where: { $0.name.contains(speakerMatch) && $0.hasOutput })
    else {
        print("no speaker matching \"\(speakerMatch)\"")
        exit(1)
    }

    // Whatever is audible becomes the far end. Nothing playing is a valid run —
    // the canceller works, it simply has no voice to remove.
    let applications = ((try? AudioApplications.grouped()) ?? []).filter(\.isPlaying)
    let farEndIDs = applications.flatMap(\.processIDs)

    print("microphone   \(mic.name)   (through the canceller)")
    print("speaker      \(speaker.name)")
    print("destination  \(destination.name)")
    print(
        "far end      "
            + (applications.isEmpty
                ? "nothing is playing — running without a reference"
                : applications.map(\.name).joined(separator: ", ")))

    let pairs = min(2, destination.outputChannels)
    let routes = (0..<pairs).map { channel in
        Route(
            source: ChannelRef(deviceUID: mic.uid, channel: 0),
            destination: ChannelRef(deviceUID: destination.uid, channel: channel))
    }

    RoutingEngine.enableAllocationTripwire()
    let before = RoutingEngine.allocationViolations

    let engine = RoutingEngine()
    do {
        try engine.start(
            sourceDeviceUID: mic.uid,
            destinationDeviceUID: destination.uid,
            routes: routes,
            preferredSampleRate: 48000,
            echoCancellation: EchoCancellationSettings(
                speakerUID: speaker.uid, farEndProcessIDs: farEndIDs,
                tapMuteBehavior: .unmuted))
    } catch {
        print("\ncould not start: \(error)")
        exit(1)
    }

    guard engine.cancelsEcho else {
        print(
            "\nthe canceller is not in the path: "
                + "\(engine.lastEchoCancellationError ?? "—")"
                + (engine.lastEchoCancellationDetail.map { " (\($0))" } ?? ""))
        engine.stop()
        exit(1)
    }
    print("\nrouting for \(Int(seconds))s…\n")

    var samples: [(produced: UInt32, buffered: UInt32)] = []
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 1)
        guard let status = engine.echoCancellationStatus else { continue }
        samples.append((status.produced, status.buffered))
        print(
            String(
                format: "  produced %8u   buffered %5u   dropped %llu   levels %@",
                status.produced, status.buffered, status.dropped,
                engine.routePeaks.map { String(format: "%.3f", $0) }
                    .joined(separator: " ")))
    }

    let status = engine.echoCancellationStatus
    engine.stop()

    let violations = RoutingEngine.allocationViolations - before
    print("")
    print("allocations on the IO thread  \(violations)")
    print(
        "far-end reference             "
            + (status?.hasReference == true ? "present" : "absent"))

    // A ring whose fill is flat is the whole claim: the canceller and the
    // router are consuming each other's output at the same rate. A fill that
    // climbs means the router is slower and latency is growing; one that falls
    // to zero means it is starving and the audio has gaps.
    guard samples.count >= 3 else {
        print("\nnot enough samples to judge the seam")
        exit(1)
    }
    let fills = samples.map { Int($0.buffered) }
    let drift = fills[fills.count - 1] - fills[1]
    print("ring fill                     \(fills.map(String.init).joined(separator: " → "))")
    print("drift over the run            \(drift) frames")

    if samples.last!.produced == samples.first!.produced {
        print("\nthe canceller stopped producing")
        exit(1)
    }
    if abs(drift) > 4800 {
        print("\nthe two ends are running at different rates — 100 ms of drift or more")
        exit(1)
    }
    print("\nthe seam holds: the canceller and the router consume each other in step")
    exit(0)
}

// One bounded answer to the question every live measurement depends on.
//
// Reusing `soak` for this looked economical and was not: soak waits ten
// seconds, samples every fifteen, runs for five minutes by default, and stdout
// is block-buffered when the gate pipes it. The supposed three-second
// preflight consequently sat in command substitution until the whole soak
// ended — or forever when coreaudiod stopped answering.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "audio-start" {
    let all = (try? AudioDevices.all()) ?? []
    guard
        let source = automaticPhysicalInput(in: all),
        let destination = all.first(where: {
            $0.uid == ClockAnchorPublisher.driverDeviceUID
        }) ?? all.first(where: { $0.transport.isVirtual && $0.hasOutput })
    else {
        print("need a real input and a loopback output")
        exit(1)
    }

    let routes = (0..<min(2, destination.outputChannels)).map { channel in
        Route(
            source: ChannelRef(deviceUID: source.uid, channel: 0),
            destination: ChannelRef(deviceUID: destination.uid, channel: channel))
    }
    let engine = RoutingEngine()
    do {
        try engine.start(
            sourceDeviceUID: source.uid, destinationDeviceUID: destination.uid,
            routes: routes, preferredSampleRate: 48000)
    } catch {
        print("could not start: \(error)")
        exit(1)
    }
    let before = engine.cycleCount
    let began = Date()
    Thread.sleep(forTimeInterval: 0.5)
    let elapsed = Date().timeIntervalSince(began)
    let cycles = engine.cycleCount - before
    engine.stop()

    let rate = elapsed > 0 ? Double(cycles) / elapsed : 0
    print(String(format: "cycle rate %.1f/s over %llu cycles", rate, cycles))
    exit(cycles > 0 ? 0 : 1)
}

/// What an independent client receives from the virtual microphone.
///
/// The router reading its own destination proves that it wrote audio, but not
/// that a separate application is scheduled often enough to receive it. This
/// opens YunAudio exactly as Discord does and asserts callback cadence without
/// sharing the router's aggregate device or IOProc.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "input-channels" {
    let match = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Seiren V3 Pro"
    let requestedSeconds =
        CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 15 : 15
    let seconds = min(20, max(1, requestedSeconds))
    let all = (try? AudioDevices.all()) ?? []
    guard
        let device = all.first(where: {
            $0.name.localizedCaseInsensitiveContains(match) && $0.hasInput
        })
    else {
        print("no input device matching \"\(match)\"")
        exit(1)
    }
    guard device.inputChannels > 0, device.inputChannels <= 8 else {
        print("unsupported input channel count: \(device.inputChannels)")
        exit(1)
    }
    let formats = device.inputStreams.compactMap(\.currentVirtualFormat)
    guard !formats.isEmpty,
        formats.allSatisfy({ format in
            if case .float(bits: 32) = format.encoding { return true }
            return false
        })
    else {
        print(
            "direct capture requires every input stream to expose Float32 to its IOProc: "
                + device.inputStreams.compactMap(\.currentVirtualFormat)
                .map(\.description).joined(separator: ", "))
        exit(1)
    }
    let sampleRate = device.nominalSampleRate
    guard sampleRate > 0, sampleRate <= 192_000 else {
        print("unsupported sample rate: \(sampleRate)")
        exit(1)
    }
    let capacityFrames = Int((sampleRate * seconds).rounded(.up)) + 4_096
    let (sampleCount, overflowed) = capacityFrames.multipliedReportingOverflow(
        by: device.inputChannels)
    guard !overflowed, sampleCount <= 32_000_000 else {
        print("capture would exceed the 128 MiB diagnostic limit")
        exit(1)
    }

    let samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    samples.initialize(repeating: 0, count: sampleCount)
    defer {
        samples.deinitialize(count: sampleCount)
        samples.deallocate()
    }
    let capture = UnsafeMutablePointer<IndependentInputCapture>.allocate(capacity: 1)
    capture.initialize(
        to: IndependentInputCapture(
            channelCount: device.inputChannels,
            capacityFrames: capacityFrames,
            samples: samples))
    defer {
        capture.deinitialize(count: 1)
        capture.deallocate()
    }

    var procID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcID(
        device.id, independentInputCaptureIOProc, UnsafeMutableRawPointer(capture), &procID)
    guard createStatus == noErr, let procID else {
        print("could not open \(device.name): \(fourCharDescription(createStatus))")
        exit(1)
    }
    defer { AudioDeviceDestroyIOProcID(device.id, procID) }

    let labels =
        DeviceChannelNames.channels(
            modelUID: device.modelUID, name: device.name,
            scope: kAudioObjectPropertyScopeInput)?.map(\.name)
        ?? (0..<device.inputChannels).map { "Channel \($0 + 1)" }
    print("direct input  \(device.name) · \(device.inputChannels)ch · \(Int(sampleRate)) Hz")
    print(
        "channels      \(labels.enumerated().map { "\($0.offset + 1)=\($0.element)" }.joined(separator: " · "))"
    )
    print("sing one continuous low-to-high note for \(Int(seconds)) seconds")

    let startStatus = AudioDeviceStart(device.id, procID)
    guard startStatus == noErr else {
        print("could not start \(device.name): \(fourCharDescription(startStatus))")
        exit(1)
    }
    Thread.sleep(forTimeInterval: seconds)
    let stopStatus = AudioDeviceStop(device.id, procID)
    guard stopStatus == noErr else {
        print("could not stop \(device.name): \(fourCharDescription(stopStatus))")
        exit(1)
    }

    let result = capture.pointee
    guard result.capturedFrames > 0, result.malformedCallbacks == 0 else {
        print(
            "capture invalid: \(result.capturedFrames) frames, "
                + "\(result.malformedCallbacks) malformed callbacks")
        exit(1)
    }
    let windowFrames = max(1, Int(sampleRate / 10))
    var channelWindows: [[InputChannelSignalWindow]] = []
    channelWindows.reserveCapacity(device.inputChannels)
    for channel in 0..<device.inputChannels {
        let start = samples + channel * capacityFrames
        let values = Array(UnsafeBufferPointer(start: start, count: result.capturedFrames))
        channelWindows.append(
            InputChannelSignalEvidence.windows(
                samples: values, windowFrames: windowFrames))
    }

    func db(_ value: Float) -> Double {
        value > 0 ? Double(20 * log10(value)) : -.infinity
    }
    print("\nEach cell is peak/RMS dBFS; −inf means every sample was exactly zero.")
    print(
        "time     "
            + labels.map {
                String($0.prefix(18)).padding(toLength: 18, withPad: " ", startingAt: 0)
            }.joined(separator: "  "))
    let rows = channelWindows.map(\.count).max() ?? 0
    for row in 0..<rows {
        let time = Double(row * windowFrames) / sampleRate
        let cells = channelWindows.map { windows -> String in
            guard row < windows.count else { return "       —/      —" }
            let window = windows[row]
            return String(format: "%7.1f/%7.1f", db(window.peak), db(window.rms))
        }
        print(String(format: "%5.1fs  %@", time, cells.joined(separator: "  ")))
    }
    print("\nsummary")
    for channel in 0..<device.inputChannels {
        let windows = channelWindows[channel]
        let peak = windows.map(\.peak).max() ?? 0
        let silent = InputChannelSignalEvidence.longestSilentRunAfterSignal(windows)
        print(
            String(
                format: "  ch%d %-18@ peak %7.1f dBFS · longest post-signal zero %.1f s",
                channel + 1, String(labels[channel].prefix(18)) as NSString, db(peak),
                Double(silent * windowFrames) / sampleRate))
    }
    print(
        "callbacks \(result.callbacks) · captured \(result.capturedFrames) frames · malformed 0"
    )
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "driver-receive" {
    let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 15 : 15
    let requiresSignal = CommandLine.arguments.contains("--require-signal")
    let all = (try? AudioDevices.all()) ?? []
    guard
        let device = all.first(where: {
            $0.uid == ClockAnchorPublisher.driverDeviceUID && $0.hasInput
        })
    else {
        print("YunAudio input is not installed")
        exit(1)
    }
    guard let bufferFrames = device.currentBufferFrameSize, bufferFrames > 0 else {
        print("YunAudio did not publish its buffer size")
        exit(1)
    }
    let sampleRate = device.nominalSampleRate
    guard sampleRate > 0 else {
        print("YunAudio did not publish its sample rate")
        exit(1)
    }

    // CoreAudio serialises calls to one IOProc. The main thread reads this only
    // after AudioDeviceStop has returned, so neither side needs a lock.
    let cadence = UnsafeMutablePointer<IndependentInputCadence>.allocate(capacity: 1)
    cadence.initialize(to: IndependentInputCadence())
    defer {
        cadence.deinitialize(count: 1)
        cadence.deallocate()
    }
    var procID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcID(
        device.id, independentInputIOProc, UnsafeMutableRawPointer(cadence), &procID)
    guard createStatus == noErr, let procID else {
        print("could not open YunAudio input: \(fourCharDescription(createStatus))")
        exit(1)
    }
    defer { AudioDeviceDestroyIOProcID(device.id, procID) }

    let startStatus = AudioDeviceStart(device.id, procID)
    guard startStatus == noErr else {
        print("could not start YunAudio input: \(fourCharDescription(startStatus))")
        exit(1)
    }
    print("reading \(device.name) as an independent client for \(Int(seconds)) s…")
    Thread.sleep(forTimeInterval: max(1, seconds))
    let stopStatus = AudioDeviceStop(device.id, procID)
    guard stopStatus == noErr else {
        print("could not stop YunAudio input: \(fourCharDescription(stopStatus))")
        exit(1)
    }

    let result = cadence.pointee
    let intervals = result.callbacks > 0 ? result.callbacks - 1 : 0
    let elapsedNanoseconds = AudioConvertHostTimeToNanos(
        result.lastHostTime - result.firstHostTime)
    let elapsed = Double(elapsedNanoseconds) / 1_000_000_000
    let callbackRate = elapsed > 0 ? Double(intervals) / elapsed : 0
    let expectedRate = sampleRate / Double(bufferFrames)
    let longestGapMilliseconds =
        Double(AudioConvertHostTimeToNanos(result.longestGap)) / 1_000_000
    let maximumAllowedGap = max(50, 4_000 / expectedRate)
    let silentPercent =
        result.callbacks > 0
        ? Double(result.silentCallbacks) / Double(result.callbacks) * 100 : 100

    print(String(format: "callbacks       %llu", result.callbacks))
    print(
        String(format: "callback rate   %.1f/s (expected %.1f/s)", callbackRate, expectedRate))
    print(
        String(
            format: "longest gap     %.2f ms (limit %.2f ms)", longestGapMilliseconds,
            maximumAllowedGap))
    print(String(format: "signal peak     %.6f", result.peak))
    print(String(format: "silent blocks   %.1f%%", silentPercent))
    let rateHeld = callbackRate >= expectedRate * 0.9
    let gapHeld = longestGapMilliseconds <= maximumAllowedGap
    let signalHeld = !requiresSignal || (result.peak > 0.01 && silentPercent <= 1)
    if rateHeld, gapHeld, signalHeld {
        print("independent input cadence held")
        exit(0)
    }
    print("independent input cadence broke")
    exit(1)
}

// Routes for a long time and watches for the things that only appear after one.
//
// Everything else here measures a few seconds. This application is meant to
// hold a call for hours, and nothing was checking what happens over that: a
// leak of a few kilobytes a minute, a cycle rate that drifts, a clock lock that
// quietly gives up an hour in. None of those are visible in an eight-second
// run, and all of them ruin the thing this is for.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "cycles" {
    // Start and stop a real route over and over, and count what the HAL is
    // still holding afterwards.
    //
    // This is the shape of #9: using the application leaves Core Audio worse
    // than it found it, until the machine needs a reboot. A route that fails to
    // tear down leaves an aggregate and its taps behind, and every cycle after
    // that adds another — so the census either stays flat or it does not, and
    // one number a cycle says which.
    let count =
        CommandLine.arguments.count > 2
        ? Int(CommandLine.arguments[2]) ?? 20 : 20
    let all = (try? AudioDevices.all()) ?? []
    guard
        let source = automaticPhysicalInput(in: all),
        let destination = all.first(where: {
            $0.uid == ClockAnchorPublisher.driverDeviceUID
        }) ?? all.first(where: { $0.transport.isVirtual && $0.hasOutput })
    else {
        print("need a real input and a virtual output")
        exit(1)
    }

    func census() -> (devices: Int, taps: Int, aggregates: Int) {
        // Through the public enumeration rather than the HAL's own array
        // bounds, which are internal to the package that owns them.
        let devices = (try? AudioDevices.all()) ?? []
        let aggregates = devices.filter { $0.transport == .aggregate }
        let taps =
            (try? AudioObjectID.system.array(of: .tapList, maximumCount: 4_096)) ?? []
        return (devices.count, taps.count, aggregates.count)
    }

    let routes = (0..<min(2, destination.outputChannels)).map { channel in
        Route(
            source: ChannelRef(deviceUID: source.uid, channel: 0),
            destination: ChannelRef(deviceUID: destination.uid, channel: channel))
    }
    let before = census()
    print("source       \(source.name)")
    print("destination  \(destination.name)")
    print("cycles       \(count)")
    print(
        "before       \(before.devices) devices, \(before.aggregates) aggregate(s), "
            + "\(before.taps) tap(s)\n")

    var failures = 0
    for cycle in 1...count {
        let engine = RoutingEngine()
        do {
            try engine.start(
                sourceDeviceUID: source.uid, destinationDeviceUID: destination.uid,
                routes: routes, preferredSampleRate: 48000)
        } catch {
            print("\(cycle): could not start — \(error)")
            failures += 1
            continue
        }
        let teardown = engine.stop(timeout: 2)
        let now = census()
        let drifted =
            now.aggregates != before.aggregates || now.taps != before.taps
        if !teardown.isComplete || drifted {
            failures += 1
            print(
                "\(cycle): teardown \(teardown), "
                    + "\(now.aggregates) aggregate(s), \(now.taps) tap(s)")
        } else if cycle % 5 == 0 || cycle == count {
            print(
                "\(cycle): clean — \(now.devices) devices, "
                    + "\(now.aggregates) aggregate(s), \(now.taps) tap(s)")
        }
    }

    let after = census()
    print("")
    print(
        "after        \(after.devices) devices, \(after.aggregates) aggregate(s), "
            + "\(after.taps) tap(s)")
    print(
        after.aggregates == before.aggregates && after.taps == before.taps
            ? "the census is where it started: nothing was left behind."
            : "SOMETHING WAS LEFT BEHIND — this is the shape of the reboot bug.")
    print("\(failures) of \(count) cycles had something to report")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "soak" {
    let minutes = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 5 : 5
    let all = (try? AudioDevices.all()) ?? []
    guard
        let source = automaticPhysicalInput(in: all),
        let destination = all.first(where: {
            $0.uid == ClockAnchorPublisher.driverDeviceUID
        }) ?? all.first(where: { $0.transport.isVirtual && $0.hasOutput })
    else {
        print("need a real input and a loopback output")
        exit(1)
    }

    print("source       \(source.name)")
    print("destination  \(destination.name)")
    print("duration     \(minutes) minutes\n")

    let routes = (0..<min(2, destination.outputChannels)).map { channel in
        Route(
            source: ChannelRef(deviceUID: source.uid, channel: 0),
            destination: ChannelRef(deviceUID: destination.uid, channel: channel))
    }

    RoutingEngine.enableAllocationTripwire()
    let violationsBefore = RoutingEngine.allocationViolations
    let engine = RoutingEngine()
    do {
        try engine.start(
            sourceDeviceUID: source.uid, destinationDeviceUID: destination.uid,
            routes: routes, preferredSampleRate: 48000)
    } catch {
        print("could not start: \(error)")
        exit(1)
    }

    /// Processor time this task has consumed, in seconds.
    ///
    /// Taken from the task rather than from `top`, so it is the router's own
    /// cost and not the sampler's. Live threads and dead ones both count —
    /// `task_info` reports only threads that have exited, so the running IO
    /// thread has to be added separately or the answer is always zero.
    func processorSeconds() -> Double {
        var total = 0.0
        var basic = task_basic_info_64()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_64>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO_64), $0, &basicCount)
            }
        }
        total += Double(basic.user_time.seconds) + Double(basic.user_time.microseconds) / 1e6
        total +=
            Double(basic.system_time.seconds) + Double(basic.system_time.microseconds) / 1e6

        var threads = task_thread_times_info()
        var threadCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &threads) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                task_info(
                    mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &threadCount)
            }
        }
        total +=
            Double(threads.user_time.seconds) + Double(threads.user_time.microseconds) / 1e6
        total +=
            Double(threads.system_time.seconds)
            + Double(threads.system_time.microseconds) / 1e6
        return total
    }

    /// Resident size in bytes, from the task itself rather than from `ps`.
    func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // Settle first: the first seconds allocate buffers and warm caches, and
    // counting those as growth would report a leak in every run.
    Thread.sleep(forTimeInterval: 10)
    let baselineBytes = residentBytes()
    let baselineCycles = engine.cycleCount
    let baselineProcessor = processorSeconds()
    let started = Date()

    print("      elapsed   cycles/s   footprint      Δ     CPU   clock")
    var samples: [(seconds: Double, cycles: Double, bytes: UInt64)] = []
    var lastCycles = baselineCycles
    var lastAt = started

    while Date().timeIntervalSince(started) < minutes * 60 {
        Thread.sleep(forTimeInterval: 15)
        let now = Date()
        let cycles = engine.cycleCount
        let rate = Double(cycles - lastCycles) / now.timeIntervalSince(lastAt)
        let bytes = residentBytes()
        let delta = Int64(bytes) - Int64(baselineBytes)
        let cpu =
            (processorSeconds() - baselineProcessor)
            / now.timeIntervalSince(started) * 100
        samples.append((now.timeIntervalSince(started), rate, bytes))
        print(
            String(
                format: "  %10.0fs %10.1f %10.2f MB %+7.2f MB %6.2f%%   %@",
                now.timeIntervalSince(started), rate,
                Double(bytes) / 1_048_576, Double(delta) / 1_048_576, cpu,
                engine.isClockLocked
                    ? String(format: "locked %.6f", engine.measuredRateRatio) : "free"))
        lastCycles = cycles
        lastAt = now
    }

    let violations = RoutingEngine.allocationViolations - violationsBefore
    let quality = engine.pathQuality
    let processorCost =
        (processorSeconds() - baselineProcessor)
        / Date().timeIntervalSince(started) * 100
    engine.stop()

    print("")
    print("allocations on the IO thread  \(violations)")
    print("path at the end               \(quality?.integrityKey ?? "—")")
    print(String(format: "processor                     %.2f%% of one core", processorCost))

    guard samples.count >= 3 else {
        print("not enough samples to judge")
        exit(1)
    }
    // Growth measured over the second half against the first, so a single
    // outlier does not decide it.
    let half = samples.count / 2
    let earlyTotal = samples[..<half].map { Double($0.bytes) }.reduce(0, +)
    let lateTotal = samples[half...].map { Double($0.bytes) }.reduce(0, +)
    let early = earlyTotal / Double(half)
    let late = lateTotal / Double(samples.count - half)
    let growthPerMinute = (late - early) / (minutes / 2) / 1024
    print(String(format: "memory growth                 %+.1f kB/min", growthPerMinute))

    let rates = samples.map(\.cycles)
    let meanRate = rates.reduce(0, +) / Double(rates.count)
    let worst = rates.map { abs($0 - meanRate) }.max() ?? 0
    print(
        String(
            format: "cycle rate                    %.1f/s, worst deviation %.1f",
            meanRate, worst))

    var failed = false
    // A megabyte an hour is 17 kB a minute; anything under that is noise from
    // the allocator rather than a leak.
    if growthPerMinute > 17 {
        print("\nmemory is growing — that is a leak, not jitter")
        failed = true
    }
    if worst > meanRate * 0.05 {
        print("\nthe cycle rate is not steady")
        failed = true
    }
    if violations > 0 {
        print("\nthe realtime contract broke during the run")
        failed = true
    }
    // Measured at 0.40% of a core for a stereo route at 128 frames. Five
    // percent is an order of magnitude of headroom and still catches anything
    // that starts doing real work per sample.
    if processorCost > 5 {
        print("\nthe processor cost has grown by an order of magnitude")
        failed = true
    }
    if failed { exit(1) }
    print("\nsteady for \(minutes) minutes")
    exit(0)
}

// Drives the Seiren V3 Pro's light ring.
//
// Every subcommand here writes to the microphone, so each one has to be asked
// for by name. Nothing probes or sweeps on its own.
//
//   light off                     brightness to zero, which is the off switch
//   light on [0-255]              brightness, default full
//   light solid <rr> <gg> <bb>    every LED one colour
//   light led <index> <r> <g> <b> one LED, the rest dark — this is how the
//                                 physical order of the ring gets established
//   light spectrum [seconds]      a hue circle, rendered here and streamed
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "light" {
    guard let device = RazerDevice.discover().first else {
        print("no Razer device exposing a vendor-defined HID usage page")
        print("run `razer --dump` to see what is actually published")
        exit(1)
    }
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard let verb = arguments.first else {
        print("usage: light [off | on | solid | led | walk | spectrum]")
        exit(1)
    }

    func report(_ status: RazerLightingCommand.Status) {
        print("device replied: \(status.description)")
        if status != .success { exit(1) }
    }

    do {
        switch verb {
        case "off":
            report(try device.send(RazerLightingCommand.brightness(0)))
        case "on":
            let level = arguments.count > 1 ? UInt8(arguments[1]) ?? 255 : 255
            report(try device.send(RazerLightingCommand.brightness(level)))
        case "solid":
            guard arguments.count >= 4, let r = UInt8(arguments[1]),
                let g = UInt8(arguments[2]), let b = UInt8(arguments[3])
            else {
                print("usage: light solid <r> <g> <b>   (0-255 each)")
                exit(1)
            }
            // Stream mode first: the device is told the host is about to push
            // frames before any frame arrives.
            _ = try device.send(RazerLightingCommand.streamMode())
            let colours = Array(
                repeating: (r: r, g: g, b: b), count: RazerLightingCommand.ledCount)
            report(try device.send(RazerLightingCommand.frame(colours)))
        case "led":
            guard arguments.count >= 5, let index = Int(arguments[1]),
                let r = UInt8(arguments[2]), let g = UInt8(arguments[3]),
                let b = UInt8(arguments[4])
            else {
                print("usage: light led <index 0-11> <r> <g> <b>")
                exit(1)
            }
            _ = try device.send(RazerLightingCommand.streamMode())
            var colours = Array(
                repeating: (r: UInt8(0), g: UInt8(0), b: UInt8(0)),
                count: RazerLightingCommand.ledCount)
            guard colours.indices.contains(index) else {
                print("index must be 0...\(RazerLightingCommand.ledCount - 1)")
                exit(1)
            }
            colours[index] = (r, g, b)
            report(try device.send(RazerLightingCommand.frame(colours)))
        case "walk":
            // The one thing the capture could not settle: which physical LED is
            // index 0, and which way round the ring the indices run. It cannot
            // be read off the device — somebody has to look at it — so this
            // lights one at a time, slowly, and says which it is lighting.
            let hold = arguments.count > 1 ? Double(arguments[1]) ?? 1.2 : 1.2
            _ = try device.send(RazerLightingCommand.streamMode())
            _ = try device.send(RazerLightingCommand.brightness(255))
            for index in 0..<RazerLightingCommand.ledCount {
                var colours = Array(
                    repeating: (r: UInt8(0), g: UInt8(0), b: UInt8(0)),
                    count: RazerLightingCommand.ledCount)
                colours[index] = (255, 255, 255)
                _ = try device.send(RazerLightingCommand.frame(colours))
                print("index \(index)")
                fflush(stdout)
                Thread.sleep(forTimeInterval: hold)
            }
            // Left as it was found rather than dark.
            let all = Array(
                repeating: (r: UInt8(255), g: UInt8(255), b: UInt8(255)),
                count: RazerLightingCommand.ledCount)
            _ = try device.send(RazerLightingCommand.frame(all))
            print("done — every index lit in turn")
        case "spectrum":
            let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 6 : 6
            _ = try device.send(RazerLightingCommand.streamMode())
            let fps = 30.0
            let total = Int(seconds * fps)
            // Rendered here rather than asked for: the device has no effects,
            // so a hue circle is arithmetic on this side.
            let frames = (0..<total).map { step -> [(r: UInt8, g: UInt8, b: UInt8)] in
                (0..<RazerLightingCommand.ledCount).map { led in
                    let hue =
                        (Double(step) / fps / 3.0
                        + Double(led) / Double(RazerLightingCommand.ledCount))
                        .truncatingRemainder(dividingBy: 1)
                    return hueToRGB(hue)
                }
            }
            print("streaming \(total) frames at \(Int(fps))fps…")
            try device.stream(frames: frames, frameInterval: 1 / fps)
            print("done")
        default:
            print("usage: light [off | on | solid | led | walk | spectrum]")
            exit(1)
        }
    } catch {
        print("failed: \(error)")
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
// Reads and moves the virtual device's own level control.
//
// The driver publishes a volume and a mute on its input scope, which is the
// side anything else reads: an application capturing it, System Settings, the
// volume keys while it is the default input. Without them macOS shows the
// device with no slider at all, which looks broken.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "volume" {
    guard let device = try? AudioDevices.device(uid: ClockAnchorPublisher.driverDeviceUID)
    else {
        print("the YunAudio device is not installed")
        exit(1)
    }
    // Both scopes, because the device appears in both lists and macOS draws a
    // slider on whichever tab you are looking at.
    let scopes: [(name: String, scope: AudioObjectPropertyScope)] = [
        ("input", kAudioObjectPropertyScopeInput),
        ("output", kAudioObjectPropertyScopeOutput),
    ]
    var chosen = scopes
    var arguments = Array(CommandLine.arguments.dropFirst(2))
    if let first = arguments.first, let match = scopes.first(where: { $0.name == first }) {
        chosen = [match]
        arguments.removeFirst()
    }

    if let argument = arguments.first {
        for entry in chosen {
            let input = entry.scope
            if argument == "mute" || argument == "unmute" {
                let muted: UInt32 = argument == "mute" ? 1 : 0
                do {
                    try device.id.setValue(
                        muted, for: AudioProperty<UInt32>.mute.scoped(to: input))
                } catch {
                    print("could not set mute: \(error)")
                    exit(1)
                }
            } else if let scalar = Float(argument) {
                do {
                    try device.id.setValue(
                        scalar, for: AudioProperty<Float32>.volumeScalar.scoped(to: input))
                } catch {
                    print("could not set the volume: \(error)")
                    exit(1)
                }
            } else {
                print("usage: volume [input|output] [0...1 | mute | unmute]")
                exit(1)
            }
        }
        // Re-read rather than trusting the write: the HAL can refuse.
        Thread.sleep(forTimeInterval: 0.1)
    }

    let fresh = (try? AudioDevices.device(uid: device.uid)) ?? device
    for entry in scopes {
        guard let scalar = fresh.volumeScalar(scope: entry.scope) else {
            print("\(entry.name)   no volume control published")
            continue
        }
        let muted = fresh.isMuted(scope: entry.scope) ? "muted" : "unmuted"
        let verdict = fresh.alters(scope: entry.scope) ? "  ← alters the signal" : ""
        print(
            String(
                format: "%-7s %.3f  %@%@", (entry.name as NSString).utf8String!,
                scalar, muted, verdict))
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "speech" {
    let deviceMatch = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "BlackHole"
    exit(playSyntheticSpeech(deviceMatch: deviceMatch) ? 0 : 1)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "tone" {
    let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 10 : 10
    let frequency =
        CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 440 : 440
    let deviceMatch = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil

    let engine = AVAudioEngine()
    let output = engine.outputNode
    if let deviceMatch {
        guard
            let device = (try? AudioDevices.all())?.first(where: {
                $0.hasOutput && $0.name.localizedCaseInsensitiveContains(deviceMatch)
            })
        else {
            print("no output device matched \(deviceMatch)")
            exit(1)
        }
        var target = device.id
        let status = AudioUnitSetProperty(
            output.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            print("could not select \(device.name): \(fourCharDescription(status))")
            exit(1)
        }
    }
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
    // Fall back to the raw process list. A grouped application is the better
    // answer when there is one — it carries every helper process — but `afplay`
    // and its kind are exactly what one reaches for to put a known signal
    // through this path, and they head no group.
    let target: (name: String, ids: [AudioObjectID], count: Int)
    if let application = applications.first(where: {
        $0.name.localizedCaseInsensitiveContains(match)
            || $0.bundleID.localizedCaseInsensitiveContains(match)
    }) {
        target = (application.name, application.processIDs, application.processCount)
    } else {
        let processes = AudioApplications.matching(
            match,
            in: (try? AudioProcesses.all(includingSilent: true)) ?? [])
        guard !processes.isEmpty else {
            print("nothing matching \"\(match)\" is producing audio")
            exit(1)
        }
        target = (
            AudioApplications.displayName(of: processes[0]), processes.map(\.id),
            processes.count
        )
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

    let capture: EchoCancellingCapture
    do {
        capture = try EchoCancellingCapture(
            microphoneUID: mic.uid, speakerUID: speaker.uid)
    } catch {
        print("could not set up the unit: \(error.reason) (\(error.detail))")
        exit(1)
    }

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

    func measure(bypassed: Bool, label: String) -> Double? {
        switch capture.setBypassed(bypassed) {
        case .applied:
            break
        case .failed(let status):
            print("  bypass property failed: \(fourCharDescription(status))")
            return nil
        case .lifecycleTimedOut(let step):
            print("  bypass property timed out at \(step?.rawValue ?? "unknown")")
            return nil
        }
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
    guard
        let bypassed = measure(bypassed: true, label: "processing bypassed"),
        let processed = measure(bypassed: false, label: "processing active   ")
    else {
        _ = capture.stop()
        exit(1)
    }
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

    let capture: EchoCancellingCapture
    do {
        capture = try EchoCancellingCapture(
            microphoneUID: mic.uid, speakerUID: speaker.uid)
    } catch {
        print(
            "AUVoiceProcessingIO could not be set up for that pair: "
                + "\(error.reason) (\(error.detail))")
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
    let devices = (try? AudioDevices.all()) ?? []
    if let defaultInput = try? AudioDevices.defaultInput(),
        !defaultInput.transport.requiresExplicitInputSelection
    {
        print("— system defaults (no device set) —")
        print(EchoCancellation.probe(inputDeviceUID: nil).summary)
    } else {
        print("— system defaults skipped: the default input is Continuity Capture —")
    }

    for device in devices
    where device.hasInput && !device.transport.requiresExplicitInputSelection {
        let duplex = device.hasOutput ? "duplex" : "input-only"
        print("\n— \(device.name)  (\(duplex)) —")
        print(EchoCancellation.probe(inputDeviceUID: device.uid).summary)
    }
    exit(0)
}

// Times the IO callback itself, off any device.
//
// `soak` says what the whole application costs and is the only thing that can;
// it also cannot resolve a change inside the route loop, because the callback
// occupies a few microseconds of every 2.7 milliseconds and the rest of the
// figure is everything else. This runs the callback and nothing else, so a
// change to the arithmetic shows up as nanoseconds rather than as noise.
//
// The checksum is printed on purpose: two builds that disagree about it are
// not two speeds of the same router.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "bench" {
    let cycles =
        CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 50_000 : 50_000
    guard (1...1_000_000).contains(cycles) else {
        print("bench cycles must be between 1 and 1000000")
        exit(2)
    }

    RoutingEngine.enableAllocationTripwire()

    let cases: [(String, RTBenchmark.Options)] = [
        ("stereo route, nothing else", .init(frames: 128, routes: 2)),
        ("stereo route, 512 frames", .init(frames: 512, routes: 2)),
        ("eight routes", .init(frames: 128, routes: 8)),
        ("+ master fader", .init(frames: 128, routes: 2, master: 0.7)),
        ("+ analysis fold", .init(frames: 128, routes: 2, analysis: true)),
        ("+ recording", .init(frames: 128, routes: 2, record: true)),
        ("stereo + monitor", .init(frames: 128, routes: 2, monitorRoutes: 2)),
        ("+ 10-section EQ", .init(frames: 128, routes: 2, monitorRoutes: 2, eqStages: 10)),
        ("+ 24-section EQ", .init(frames: 128, routes: 2, monitorRoutes: 2, eqStages: 24)),
        // 2688 frames is 56 ms at 48 kHz — voice isolation, the longest stage
        // here, and so the most alignment anything asks for.
        ("+ tap alignment", .init(frames: 128, routes: 2, alignmentFrames: 2688)),
        // Deliberately without the alignment, so this row stays comparable with
        // every measurement taken before the delay lines existed. The row above
        // is what the alignment costs.
        (
            "everything on",
            .init(
                frames: 128, routes: 8, monitorRoutes: 2, eqStages: 10,
                analysis: true, record: true, master: 0.7)
        ),
    ]

    print("  best of 5 runs of \(cycles) cycles each\n")
    print("  case                          ns/cycle   ns/frame   alloc   checksum")
    var broke = false
    for (name, options) in cases {
        // Best of several rather than the mean. The distribution is one-sided:
        // nothing makes a run faster than the work takes, and everything else
        // on the machine can make one slower. Averaging measures the other
        // tenants; the minimum measures this code. It is also what brought the
        // run-to-run scatter on the cheap cases down from 35% to about 2%,
        // which is the difference between seeing a change and guessing at one.
        var best = Double.infinity
        var allocations: UInt64 = 0
        var checksum = 0.0
        var wasAdmitted = true
        for _ in 0..<5 {
            guard let result = RTBenchmark.run(options, cycles: cycles) else {
                print("invalid built-in benchmark configuration: \(name)")
                broke = true
                wasAdmitted = false
                break
            }
            best = min(best, result.nanosecondsPerCycle)
            allocations += result.allocations
            checksum = result.checksum
        }
        guard wasAdmitted else { continue }
        print(
            String(
                format: "  %-28s %8.1f %10.2f %7llu   %+.6e",
                (name as NSString).utf8String!, best,
                best / Double(options.frames), allocations, checksum))
        if allocations > 0 { broke = true }
    }

    RoutingEngine.disableAllocationTripwire()
    if broke {
        print("\nsomething on the IO thread allocated — that is the invariant, not the timing")
        exit(1)
    }
    print("\nno allocation on the IO thread in any case")
    exit(0)
}

/// Who has the microphone open, and whether a Bluetooth output has paid for it.
///
/// Read-only. Answers the question macOS shows an orange dot for and never
/// names: which application is holding an input right now.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "mic" {
    // The grouped list rather than the raw one, because that is what the
    // interface shows — and because it is the path that resolves a name for a
    // process with no bundle. "PID 48275" is not a row anybody can act on.
    let applications = (try? AudioApplications.grouped()) ?? []
    let recording = applications.filter(\.isRecording)
    print(
        "\(applications.count) application(s), \(recording.count) with an input open")
    for application in recording {
        print("  \(application.name)  [\(application.bundleID)]")
    }

    let outputs = ((try? AudioDevices.all()) ?? []).filter(\.hasOutput)
    let wireless = outputs.filter { $0.transport.isBluetooth }
    print("\n\(wireless.count) Bluetooth output(s)")
    for device in wireless {
        let rate = device.currentSampleRate ?? 0
        print(
            "  \(device.name): \(Int(rate)) Hz — "
                + (device.hasFallenToCallQuality
                    ? "call quality; something has its microphone open"
                    : "full quality"))
    }
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "fidelity" {
    // What each conditioning effect costs, against one repeatable signal.
    //
    // Every default in this application that touches the sound was chosen on
    // somebody's judgement. This is the arithmetic that judgement can be
    // checked against — and the first thing it says is that at their default
    // settings several of these effects are bit-transparent, which is not what
    // anybody assumed.
    let rate =
        CommandLine.arguments.count > 2
        ? Double(CommandLine.arguments[2]) ?? 48_000 : 48_000
    let source = SignalFidelity.fixture(seconds: 2, sampleRate: rate)
    print("one repeatable signal, \(Int(rate)) Hz, 2 s, through each effect alone\n")
    print("effect          delay     gain     residual      r       loudest band")
    print(String(repeating: "-", count: 78))
    for kind in EffectKind.allCases {
        guard let measured = SignalFidelity.cost(of: [kind], on: source, sampleRate: rate)
        else {
            print(
                "\(kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))  would not build at this rate"
            )
            continue
        }
        let worst = measured.bandDecibels.max { abs($0.decibels) < abs($1.decibels) }
        let band =
            worst.map { String(format: "%5.0f Hz %+6.2f dB", $0.centreHertz, $0.decibels) }
            ?? "—"
        let name = kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
        let residual =
            measured.residualDecibels.isFinite
            ? String(format: "%+8.2f dB", measured.residualDecibels)
            : "  exact   "
        print(
            String(
                format: "%@  %5d  %+7.2f  %@  %.5f  %@",
                name, measured.delayFrames, measured.gainDecibels, residual,
                measured.correlation, band))
    }
    print("")
    // The one thing in the default configuration that changes the signal.
    print("")
    print("and the conversion that is in almost every path, with nothing switched on:")
    print("")
    for (from, through) in [(44_100.0, 48_000.0), (48_000.0, 44_100.0), (96_000.0, 48_000.0)] {
        // Band-limited, because white noise fills its own Nyquist and the
        // conversion is then measured on content it is required to remove.
        let material = SignalFidelity.bandLimitedFixture(seconds: 2, sampleRate: from)
        guard
            let measured = SignalFidelity.costOfResampling(
                from: from, through: through, on: material)
        else {
            print(
                String(
                    format: "  %6.0f → %6.0f → %6.0f Hz   could not be set up", from, through,
                    from))
            continue
        }
        let residual =
            measured.residualDecibels.isFinite
            ? String(format: "%+8.2f dB", measured.residualDecibels)
            : "  exact   "
        print(
            String(
                format: "  %6.0f → %6.0f → %6.0f Hz   residual %@  r %.5f",
                from, through, from, residual, measured.correlation))
    }
    print("")
    print("residual is what is left once the delay and the level are taken out —")
    print("the part a fader cannot undo. \"exact\" means the samples came back")
    print("unchanged: that effect costs nothing at its default setting.")
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "dsp" {
    for frames in [64, 128, 256, 512] {
        print(SoundIsolation.probe(sampleRate: 48000, blockFrames: frames).summary)
        print("")
    }
    exit(0)
}

/// Whether the detector actually fires, proved without a room.
///
/// The awkward part of asserting anything about a voice detector is that it
/// reads a microphone, and a check that needs somebody to speak into one is a
/// check that never runs. A loopback device closes the loop: speech is
/// synthesised, played into its output, and read back from its input, which is
/// the same signal path the detector sees on real hardware minus the acoustics.
///
/// The header's caveat is the reason for the IOProc that does nothing — with
/// input not running, the state reads 0 whatever is being said.
private func proveVoiceActivity(deviceMatch: String) -> Bool {
    guard
        let device = (try? AudioDevices.all())?.first(where: {
            $0.hasInput && $0.name.localizedCaseInsensitiveContains(deviceMatch)
        })
    else {
        print("no input device matched \(deviceMatch)")
        return false
    }
    print("proving voice activity detection on \(device.name)")

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var voiced = false
        private var changes = 0
        func record(_ speaking: Bool) {
            lock.lock()
            changes += 1
            if speaking { voiced = true }
            lock.unlock()
        }
        var heardVoice: Bool { lock.lock(); defer { lock.unlock() }; return voiced }
        var changeCount: Int { lock.lock(); defer { lock.unlock() }; return changes }
    }
    let seen = Seen()

    // Input running, or the state is 0 by definition. The proc does nothing
    // with what it reads: the point is that the device's input side is live.
    // The proc also meters, because a negative result from the detector means
    // nothing unless the signal reached its input. A loopback that carried
    // silence and a detector that ignored speech look identical from outside.
    final class Level: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Float = 0
        func offer(_ peak: Float) { lock.lock(); value = max(value, peak); lock.unlock() }
        var peak: Float { lock.lock(); defer { lock.unlock() }; return value }
    }
    let level = Level()

    var procID: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) {
        _, inputData, _, _, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        var peak: Float = 0
        for index in 0..<buffers.count {
            guard let data = buffers[index].mData else { continue }
            let count = Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<count { peak = max(peak, abs(samples[frame])) }
        }
        level.offer(peak)
    }
    guard status == noErr, let procID else {
        print("could not open an input proc: \(fourCharDescription(status))")
        return false
    }
    defer { AudioDeviceDestroyIOProcID(device.id, procID) }
    AudioDeviceStart(device.id, procID)
    defer { AudioDeviceStop(device.id, procID) }

    guard
        let watcher = VoiceActivityWatcher(
            device: device.id,
            activation: .enableIfNeeded,
            onChange: { seen.record($0) })
    else {
        print("this device does not publish the detector")
        return false
    }
    defer { watcher.stop() }
    print("  detection enabled: \(watcher.isObserving)")

    // Speech rather than noise, because the detector is a voice detector: a
    // burst of white noise at the same level is exactly what it exists not to
    // report.
    let engine = AVAudioEngine()
    let output = engine.outputNode
    var target = device.id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitSetProperty(
        output.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &target, size)

    let synthesiser = AVSpeechSynthesizer()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    do { try engine.start() } catch {
        print("could not start the engine: \(error)")
        return false
    }

    var scheduled = 0
    let utterance = AVSpeechUtterance(
        string: "The quick brown fox jumps over the lazy dog, and says it twice.")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesiser.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
        guard let converted = convert(pcm, to: engine.mainMixerNode.outputFormat(forBus: 0))
        else { return }
        player.scheduleBuffer(converted, completionHandler: nil)
        scheduled += 1
        if !player.isPlaying { player.play() }
    }

    // Two distinct failures, kept apart. A run where the loopback carried
    // nothing says nothing about the detector, and reporting it as "the
    // detector ignored speech" would be inventing a finding — one run in three
    // lost the race between the engine starting and the window closing, and
    // without the meter that looked exactly like a detector that does not work.
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, !seen.heardVoice {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard level.peak > 0.01 else {
        print(
            String(
                format: "  the loopback carried nothing (peak %.3f) — inconclusive",
                level.peak))
        engine.stop()
        return false
    }
    print(
        String(
            format: "  %d buffer(s) of speech played, peak at the input %.3f, %d change(s)",
            scheduled, level.peak, seen.changeCount))
    print(
        seen.heardVoice
            ? "  the detector reported voice" : "  the detector never reported voice")
    engine.stop()
    return seen.heardVoice
}

/// Resamples and rechannels one buffer, since the synthesiser's format is its
/// own and the device's is the device's.
private func convert(
    _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat
) -> AVAudioPCMBuffer? {
    // Both rates before the division: a rate of zero makes the ratio infinite,
    // and that reaches `AVAudioFrameCount` and kills the process from inside
    // the standard library.
    guard buffer.format.sampleRate > 0, format.sampleRate > 0,
        let converter = AVAudioConverter(from: buffer.format, to: format)
    else { return nil }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
        return nil
    }
    var done = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if done {
            status.pointee = .endOfStream
            return nil
        }
        done = true
        status.pointee = .haveData
        return buffer
    }
    return error == nil && out.frameLength > 0 ? out : nil
}

/// What CoreAudio's own voice activity detector is available on, and what it
/// says. Read-only unless `--watch` is given, which switches detection on for
/// one device and puts it back afterwards.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "vad" {
    let devices = (try? AudioDevices.all())?.filter(\.hasInput) ?? []
    print("voice activity detection — \(devices.count) input device(s)")
    print(String(repeating: "=", count: 60))
    for device in devices {
        let available = VoiceActivityWatcher.isAvailable(on: device.id)
        let enabled = VoiceActivityWatcher.isEnabled(on: device.id)
        let state = VoiceActivityWatcher.state(of: device.id)
        let reference = VoiceActivityWatcher.suggestedReferenceDeviceUID(for: device.id)
        print("\n\(device.name)")
        print("  publishes 'vAd+'   \(available ? "yes" : "no")")
        print("  currently enabled  \(enabled ? "yes" : "no")")
        print(
            "  'vAdS' says        "
                + (state.map { $0 ? "voice" : "no voice" } ?? "the property is absent"))
        // An empty string is what the property answers with when the system
        // has no suggestion, which is not the same as the property being
        // absent and must not read as a device named "".
        let referenceText =
            (reference?.isEmpty == false)
            ? reference! : "none suggested — the default output"
        print("  echo reference     \(referenceText)")
    }

    if CommandLine.arguments.contains("--prove") {
        let match = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "BlackHole"
        exit(proveVoiceActivity(deviceMatch: match) ? 0 : 1)
    }

    if CommandLine.arguments.contains("--watch") {
        let match = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
        let candidates =
            match.isEmpty
            ? devices.filter { !$0.transport.requiresExplicitInputSelection }
            : devices
        guard
            let device = candidates.first(where: {
                match.isEmpty || $0.name.localizedCaseInsensitiveContains(match)
            })
        else {
            print("\nno input device matched \(match)")
            exit(1)
        }
        print("\nwatching \(device.name) for 20 s — say something")
        // A class rather than a captured `var`: the callback arrives on the
        // watcher's own queue, and Swift 6 will not let a closure that escapes
        // to another thread mutate a local.
        final class Changes: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let changes = Changes()
        guard
            let watcher = VoiceActivityWatcher(
                device: device.id,
                activation: .enableIfNeeded,
                onChange: { speaking in
                    changes.bump()
                    print("  \(speaking ? "voice" : "silence")")
                })
        else {
            print("this device does not publish the detector")
            exit(1)
        }
        // The header is explicit that the state reads 0 when input is not
        // running, so this is only meaningful with something recording. That is
        // the caveat rather than a fault, and it is printed rather than hidden.
        print("  (input has to be running somewhere, or this stays silent)")
        RunLoop.current.run(until: Date().addingTimeInterval(20))
        print("\n\(changes.count) change(s), still observing: \(watcher.isObserving)")
        watcher.stop()
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
    let callChain = CommandLine.arguments.contains("--call-chain")
    let sourceChannel: Int? = {
        guard let flag = CommandLine.arguments.firstIndex(of: "--source-channel"),
            flag + 1 < CommandLine.arguments.count,
            let oneBased = Int(CommandLine.arguments[flag + 1]), oneBased > 0
        else { return nil }
        return oneBased - 1
    }()
    do {
        try runRoute(
            sourceMatch: source, destinationMatch: destination, seconds: seconds,
            voiceIsolation: isolation,
            effects: callChain ? [.voiceIsolation, .equaliser, .gate, .limiter] : [],
            bufferFrames: callChain ? 256 : 128,
            preferredSampleRate: callChain ? 48000 : nil,
            sourceChannel: sourceChannel)
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

/// Hue at full saturation and value, for the spectrum sweep.
func hueToRGB(_ hue: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
    let sector = hue * 6
    let offset = sector - sector.rounded(.down)
    let rising = UInt8(offset * 255)
    let falling = UInt8((1 - offset) * 255)
    switch Int(sector) % 6 {
    case 0: return (255, rising, 0)
    case 1: return (falling, 255, 0)
    case 2: return (0, 255, rising)
    case 3: return (0, falling, 255)
    case 4: return (rising, 0, 255)
    default: return (255, 0, falling)
    }
}
