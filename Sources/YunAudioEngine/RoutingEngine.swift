import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// Carries the realtime graph pointer onto the clock publisher's queue.
///
/// The `@unchecked` is claimed deliberately, not to quiet the compiler: the
/// storage is allocated before the device starts and freed only after both the
/// IOProc has been destroyed and the publisher's queue has been drained, and
/// the only field read across threads is guarded by the graph's cycle counter
/// acting as a sequence number.
private struct GraphHandle: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<RTGraph>
}

/// Where a signal comes from, in device terms rather than buffer terms.
public struct ChannelRef: Sendable, Hashable {
    /// UID of the sub-device inside the aggregate.
    public let deviceUID: String
    /// Zero-based channel within that device.
    public let channel: Int

    public init(deviceUID: String, channel: Int) {
        self.deviceUID = deviceUID
        self.channel = channel
    }
}

public struct Route: Sendable, Hashable {
    public let source: ChannelRef
    public let destination: ChannelRef
    public var gain: Float
    public var isMuted: Bool

    public init(
        source: ChannelRef, destination: ChannelRef,
        gain: Float = 1.0, isMuted: Bool = false
    ) {
        self.source = source
        self.destination = destination
        self.gain = gain
        self.isMuted = isMuted
    }
}

/// Voice isolation configuration.
public struct VoiceIsolationSettings: Sendable, Hashable {
    /// 0 = untouched, 100 = fully isolated.
    public var mixPercent: Float
    /// The higher quality model, available from macOS 15.
    public var isHighQuality: Bool

    public init(mixPercent: Float = 100, isHighQuality: Bool = true) {
        self.mixPercent = mixPercent
        self.isHighQuality = isHighQuality
    }
}

/// How faithful a configured path actually is.
public struct PathQuality: Sendable, Hashable {
    /// True when the signal reaches the destination unaltered: nothing
    /// resamples it and nothing processes it.
    public let isBitExact: Bool
    /// A DSP stage is inserted. Bit-exactness is impossible while this is true —
    /// processing the signal is the entire point of the stage.
    public let hasProcessing: Bool
    /// True when the destination is the YunAudio driver and it has confirmed it
    /// is tracking the master's measured rate.
    public let isClockLocked: Bool
    /// Measured master rate over its nominal rate. 1.00002 is twenty ppm fast.
    public let measuredRateRatio: Double
    /// Sub-devices the HAL is drift-correcting, and therefore resampling.
    public let driftCorrectedDeviceUIDs: [String]
    public let bufferFrames: Int
    public let sampleRate: Double

    public var bufferLatencyMilliseconds: Double {
        sampleRate > 0 ? Double(bufferFrames) / sampleRate * 1000 : 0
    }
}

/// Drives one private aggregate device through a single IOProc.
///
/// `@unchecked Sendable` is earned rather than asserted: every mutation of the
/// engine's own state goes through `stateLock`, and the realtime graph it hands
/// to the IOProc is freed only after that proc has been destroyed. The clock
/// publisher calls back from its own queue, so the type genuinely does cross
/// threads and the serialisation has to be real.
public final class RoutingEngine: @unchecked Sendable {
    private let stateLock = NSRecursiveLock()
    public private(set) var aggregate: AggregateDevice?
    public private(set) var isRunning = false

    private var ioProcID: AudioDeviceIOProcID?
    private var graph: UnsafeMutablePointer<RTGraph>?
    /// What the IOProc actually reads. Holding the graph behind this is what
    /// makes a route change a swap rather than a restart.
    private var graphCell: OpaquePointer?
    private var activeRoutes: [Route] = []

    /// The routes currently carrying audio, including any built from taps.
    public var currentRoutes: [Route] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRoutes
    }
    /// Maps a device channel onto the (buffer, channel) pair the IOProc sees.
    private var inputMap: [ChannelRef: (buffer: Int32, channel: Int32)] = [:]
    private var outputMap: [ChannelRef: (buffer: Int32, channel: Int32)] = [:]
    private var clockPublisher: ClockAnchorPublisher?
    private var selftestBlock: UnsafeMutablePointer<RTSelftest>?
    /// Retained here so the unit outlives the unmanaged pointer the IO thread
    /// holds; the IOProc must never touch a reference count.
    private var isolationUnit: VoiceIsolationUnit?
    private var isolationBlock: UnsafeMutablePointer<RTVoiceIsolation>?
    private var isolationFailureCounter: UnsafeMutablePointer<UInt64>?

    /// Latency the isolation model adds, in frames. Zero when it is off.
    public private(set) var voiceIsolationLatencyFrames = 0
    /// Latency every enabled processing stage adds together, in frames.
    public private(set) var effectLatencyFrames = 0
    private var effectChain: EffectChain?
    /// Renders the model refused. Non-zero means audio passed through
    /// unprocessed, which the UI should surface rather than hide.
    public var voiceIsolationFailures: UInt64 { isolationFailureCounter?.pointee ?? 0 }
    /// True when drift correction was switched off on the strength of the
    /// driver's clock locking, so the path is only clean while the lock holds.
    private var requiresClockLock = false
    /// Sample rates as they were before routing touched them.
    private var originalSampleRates: [String: Double] = [:]
    /// Enough of the last start() to bring the route back up unaided.
    private var lastConfiguration:
        (
            source: String, destination: String, routes: [Route], bufferFrames: UInt32
        )?
    /// Set once a lock failure has forced drift correction back on, so the
    /// recovery cannot loop.
    private var clockLockAbandoned = false
    private let recoveryQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.route-recovery")

    /// Reports a route that had to be rebuilt because the clock lock failed.
    public var onClockLockFailure: (@Sendable () -> Void)?

    public private(set) var lastIsolationError: String?

    public init() {}

    deinit { stop() }

    // MARK: Lifecycle

    /// Builds the aggregate, resolves channel mappings, installs the IOProc and
    /// starts the device.
    ///
    /// - Parameters:
    ///   - sourceDeviceUID: The physical input. It becomes the clock master, so
    ///     its samples are never resampled.
    ///   - destinationDeviceUID: The virtual output the routed signal lands in.
    ///   - routes: Channel-level connections between the two.
    ///   - taps: Application captures to fold in as extra source channels.
    ///   - additionalDestinationUIDs: Further outputs to bind, so a tapped
    ///     application can be sent somewhere other than the main destination.
    ///   - effects: Processing stages to insert ahead of the routes. More than
    ///     one supersedes `voiceIsolation`, which is the single-stage form.
    ///   - preferredSampleRate: Used when both devices support it, rather than
    ///     always taking the highest common rate — a voice chat gains nothing
    ///     above 48 kHz.
    ///   - bufferFrames: IO cycle size. 128 frames is 2.7 ms at 48 kHz.
    ///   - voiceIsolation: Single-stage isolation settings, or nil for none.
    ///   - selftest: Installs the loopback integrity check.
    /// - Throws: `RoutingError` when a device is missing, a channel cannot be
    ///   mapped, the devices share no sample rate, or CoreAudio refuses to
    ///   create or start the aggregate.
    public func start(
        sourceDeviceUID: String,
        destinationDeviceUID: String,
        routes: [Route],
        taps: [ProcessTap] = [],
        additionalDestinationUIDs: [String] = [],
        effects: [EffectKind] = [],
        preferredSampleRate: Double? = nil,
        bufferFrames: UInt32 = 128,
        voiceIsolation: VoiceIsolationSettings? = nil,
        selftest: Bool = false
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()

        guard let source = try AudioDevices.device(uid: sourceDeviceUID) else {
            throw RoutingError.deviceNotFound(sourceDeviceUID)
        }
        guard let destination = try AudioDevices.device(uid: destinationDeviceUID) else {
            throw RoutingError.deviceNotFound(destinationDeviceUID)
        }

        // Align rates before assembling: a mismatch inside the aggregate forces
        // conversion on paths that would otherwise be clean.
        //
        // The caller's preferred rate wins when both devices support it. Falling
        // back to the highest common rate would quietly put a voice chat at
        // 96 kHz, which only buys a resample back to 48 kHz at the far end.
        // Extra destinations let a tapped application be sent somewhere other
        // than the microphone's destination — one app to the headphones while
        // the rest of the mix goes to the virtual device.
        let extras =
            additionalDestinationUIDs
            .filter { $0 != sourceDeviceUID && $0 != destinationDeviceUID }
            .compactMap { try? AudioDevices.device(uid: $0) }
        let members = [source, destination] + extras
        let shared = Set(source.availableSampleRates)
            .intersection(destination.availableSampleRates)
        let rate: Double
        if let preferred = preferredSampleRate, shared.contains(preferred) {
            rate = preferred
        } else if let highest = shared.max() {
            rate = highest
        } else {
            throw RoutingError.noCommonSampleRate
        }
        // Remembered so the devices go back the way they were found. Merged
        // rather than replaced: a restart must not forget what the first start
        // changed.
        let changed = try AggregateDevice.alignSampleRate(rate, across: members)
        for (uid, previous) in changed where originalSampleRates[uid] == nil {
            originalSampleRates[uid] = previous
        }

        // If the destination is our own driver and it implements clock anchors,
        // it will track the microphone's measured rate itself, so asking the
        // HAL to drift-correct it as well would resample a signal that does not
        // need it. Any other destination keeps drift correction on.
        //
        // Turning it off up front rather than after the lock converges is safe:
        // convergence takes about a second and a half, and a crystal tens of
        // parts per million out accumulates only microseconds in that window.
        let clockLockAvailable =
            !clockLockAbandoned
            && destinationDeviceUID == ClockAnchorPublisher.driverDeviceUID
            && (ClockAnchorPublisher(driverDeviceUID: destinationDeviceUID)?
                .driverSupportsClockLocking ?? false)
        requiresClockLock = clockLockAvailable
        lastConfiguration = (
            sourceDeviceUID, destinationDeviceUID, routes, bufferFrames
        )

        // The microphone is the clock master; the virtual device follows it.
        // Doing it the other way round would resample the signal we are trying
        // to carry intact.
        let aggregate = try AggregateDevice(
            name: "YunAudio Route",
            subDevices: [
                .init(uid: sourceDeviceUID, driftCompensation: false),
                .init(uid: destinationDeviceUID, driftCompensation: !clockLockAvailable),
            ] + extras.map { .init(uid: $0.uid, driftCompensation: true) },
            clockMasterUID: sourceDeviceUID,
            taps: taps)
        self.aggregate = aggregate

        try? aggregate.setBufferFrameSize(bufferFrames)

        try buildChannelMaps(aggregate: aggregate, members: members, taps: taps)

        // Isolation is a mono stage fed from one source channel, so it is set
        // up before the routes are resolved: a route that reads the model's
        // output has a different stride and channel index from one that reads
        // the raw device buffer.
        // A chain of more than one stage supersedes the single isolation slot:
        // it renders the same model plus whatever else is switched on, so
        // running both would process the signal twice.
        var isolatedSource: ChannelRef?
        if effects.count > 1, let first = routes.first {
            isolatedSource = first.source
            if let chain = EffectChain(
                kinds: effects, sampleRate: rate, maximumFrames: Int(bufferFrames))
            {
                effectChain = chain
                effectLatencyFrames = chain.latencyFrames
                voiceIsolationLatencyFrames =
                    effects.contains(.voiceIsolation) ? chain.latencyFrames : 0
            } else {
                isolatedSource = nil
                lastIsolationError = "the processing chain could not be built"
            }
        } else if let settings = voiceIsolation, let first = routes.first {
            isolatedSource = first.source
            let unit = VoiceIsolationUnit(
                sampleRate: rate, maximumFrames: Int(bufferFrames))
            if let unit {
                unit.setMix(settings.mixPercent)
                unit.setHighQuality(settings.isHighQuality)
                isolationUnit = unit
                voiceIsolationLatencyFrames = unit.latencyFrames
            } else {
                // Not fatal: the route still carries audio, just unprocessed.
                isolatedSource = nil
                lastIsolationError = "AUSoundIsolation could not be instantiated"
            }
        }

        let rtRoutes = try routes.map { route -> RTRoute in
            guard let sourcePoint = inputMap[route.source] else {
                throw RoutingError.channelNotFound(route.source, isInput: true)
            }
            guard let destinationPoint = outputMap[route.destination] else {
                throw RoutingError.channelNotFound(route.destination, isInput: false)
            }
            return RTRoute(
                sourceBuffer: sourcePoint.buffer,
                sourceChannel: sourcePoint.channel,
                destinationBuffer: destinationPoint.buffer,
                destinationChannel: destinationPoint.channel,
                gain: route.gain,
                muted: route.isMuted,
                usesIsolatedSource: isolatedSource != nil && route.source == isolatedSource)
        }

        let graph = RTGraph.allocate(
            routes: rtRoutes, bufferFrames: Int(bufferFrames), sampleRate: rate)
        self.graph = graph
        activeRoutes = routes

        if let chain = effectChain, let reference = isolatedSource,
            let point = inputMap[reference]
        {
            let failures = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            failures.initialize(to: 0)
            isolationFailureCounter = failures

            let block = UnsafeMutablePointer<RTVoiceIsolation>.allocate(capacity: 1)
            block.initialize(
                to: RTVoiceIsolation(
                    enabled: 1,
                    sourceBuffer: point.buffer,
                    sourceChannel: point.channel,
                    unit: Unmanaged.passUnretained(chain).toOpaque(),
                    inputBuffer: chain.inputBuffer,
                    outputBuffer: chain.outputBuffer,
                    maximumFrames: Int32(chain.maximumFrames),
                    renderFailures: failures))
            isolationBlock = block
            graph.pointee.voiceIsolation = block
            graph.pointee.isolationIsChain = 1
        } else if let unit = isolationUnit, let reference = isolatedSource,
            let point = inputMap[reference]
        {
            let failures = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            failures.initialize(to: 0)
            isolationFailureCounter = failures

            let block = UnsafeMutablePointer<RTVoiceIsolation>.allocate(capacity: 1)
            block.initialize(
                to: RTVoiceIsolation(
                    enabled: 1,
                    sourceBuffer: point.buffer,
                    sourceChannel: point.channel,
                    unit: Unmanaged.passUnretained(unit).toOpaque(),
                    inputBuffer: unit.inputBuffer,
                    outputBuffer: unit.outputBuffer,
                    maximumFrames: Int32(unit.maximumFrames),
                    renderFailures: failures))
            isolationBlock = block
            graph.pointee.voiceIsolation = block
        }

        // The integrity check writes its sequence to the destination's first
        // output channel and reads the same channel back off its input. Both
        // ends live inside this one aggregate, so a returned sample really did
        // travel the whole path.
        if selftest {
            let outRef = ChannelRef(deviceUID: destinationDeviceUID, channel: 0)
            let inRef = ChannelRef(deviceUID: destinationDeviceUID, channel: 0)
            guard let outPoint = outputMap[outRef] else {
                throw RoutingError.channelNotFound(outRef, isInput: false)
            }
            guard let inPoint = inputMap[inRef] else {
                throw RoutingError.channelNotFound(inRef, isInput: true)
            }
            let block = RTSelftest.allocate(
                outBuffer: outPoint.buffer, outChannel: outPoint.channel,
                inBuffer: inPoint.buffer, inChannel: inPoint.channel,
                captureFrames: 262_144)
            selftestBlock = block
            graph.pointee.selftest = block
        }

        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))
        graphCell = cell

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            aggregate.id, yunAudioIOProc, UnsafeMutableRawPointer(cell), &procID)
        guard createStatus == noErr, let procID else {
            throw RoutingError.ioProcFailed(createStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate.id, procID)
        guard startStatus == noErr else {
            throw RoutingError.startFailed(startStatus)
        }
        isRunning = true

        // When the destination is our own driver, hand it the master's clock so
        // it can lock to the microphone. Any other destination — BlackHole, a
        // physical device — has no such channel, and the path stays honestly
        // marked as resampled.
        if clockLockAvailable,
            let publisher = ClockAnchorPublisher(driverDeviceUID: destinationDeviceUID)
        {
            clockPublisher = publisher
            // Captures the graph pointer, not self: the closure runs on the
            // publisher's own queue, and stop() drains that queue before the
            // graph is freed, so the pointer stays valid for every call.
            let handle = GraphHandle(pointer: graph)
            let anchorRate = rate

            // Drift correction is off because the driver promised to track the
            // microphone. If that promise stops being kept — the application
            // was starved and missed its anchor deadline — nothing is
            // correcting a crystal that is parts per million out, and the error
            // accumulates into dropouts. Rebuild the route with the HAL back in
            // charge rather than let it rot silently.
            publisher.onLockChanged = { [weak self] locked in
                guard !locked, let self else { return }
                self.recoveryQueue.async { self.recoverFromClockLockLoss() }
            }
            publisher.start {
                RoutingEngine.anchor(from: handle.pointer, sampleRate: anchorRate)
            }
        }
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        clockPublisher?.onLockChanged = nil
        clockPublisher?.stop()
        clockPublisher = nil
        requiresClockLock = false

        if let aggregate, let ioProcID {
            if isRunning { AudioDeviceStop(aggregate.id, ioProcID) }
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        ioProcID = nil
        isRunning = false

        aggregate?.destroy()
        aggregate = nil

        // Safe now: the IOProc has been destroyed, so nothing can be reading
        // the graph any more.
        if let graph { RTGraph.deallocate(graph) }
        graph = nil
        if let graphCell { yun_rt_cell_free(graphCell) }
        graphCell = nil
        stopRecordingLocked()
        if let selftestBlock { RTSelftest.deallocate(selftestBlock) }
        selftestBlock = nil

        // Order matters: the block is freed first so nothing can dereference
        // the unmanaged unit pointer afterwards, then the unit is released.
        if let isolationBlock {
            isolationBlock.deinitialize(count: 1)
            isolationBlock.deallocate()
        }
        isolationBlock = nil
        if let isolationFailureCounter {
            isolationFailureCounter.deinitialize(count: 1)
            isolationFailureCounter.deallocate()
        }
        isolationFailureCounter = nil
        isolationUnit = nil
        effectChain = nil
        voiceIsolationLatencyFrames = 0
        effectLatencyFrames = 0

        inputMap.removeAll()
        outputMap.removeAll()
        activeRoutes.removeAll()

        // Restore last: the aggregate has to be gone first, or the HAL will
        // simply set the rate back to whatever the aggregate wanted.
        if !originalSampleRates.isEmpty {
            AggregateDevice.restoreSampleRates(originalSampleRates)
            originalSampleRates.removeAll()
        }
    }

    /// Brings the route back up with drift correction enabled after the clock
    /// lock dropped. Runs on `recoveryQueue`, never on the publisher's queue —
    /// stopping the publisher drains that queue and would deadlock on itself.
    private func recoverFromClockLockLoss() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard requiresClockLock, !clockLockAbandoned,
            let configuration = lastConfiguration
        else { return }
        clockLockAbandoned = true

        try? start(
            sourceDeviceUID: configuration.source,
            destinationDeviceUID: configuration.destination,
            routes: configuration.routes,
            bufferFrames: configuration.bufferFrames)
        onClockLockFailure?()
    }

    // MARK: Recording

    private var recorder: Recorder?

    /// True while audio is being written to disk.
    public var isRecording: Bool { recorder != nil }
    public var recordingURL: URL? { recorder?.url }
    public var recordingDuration: TimeInterval { recorder?.duration ?? 0 }

    /// Starts writing the routed signal to a file.
    ///
    /// - Throws: Whatever creating the file throws — a directory that does not
    ///   exist, or is not writable.
    @discardableResult
    public func startRecording(
        to directory: URL, format: Recorder.Format = .wav, now: Date = Date()
    ) throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, let graph, let device = aggregate?.device else {
            throw RecorderError.couldNotAllocate
        }
        stopRecordingLocked()

        let channels = min(2, device.outputChannels)
        let recorder = try Recorder(
            directory: directory, format: format, channels: channels,
            sampleRate: device.currentSampleRate ?? 48000, timestamp: now)
        self.recorder = recorder
        graph.pointee.recordChannels = Int32(channels)
        graph.pointee.recordRing = recorder.ringHandle
        return recorder.url
    }

    public func stopRecording() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopRecordingLocked()
    }

    private func stopRecordingLocked() {
        guard let recorder else { return }
        // Detach from the graph first: the writer thread must not be draining a
        // ring the IO thread is still filling while it is being torn down.
        graph?.pointee.recordRing = nil
        graph?.pointee.recordChannels = 0
        recorder.stop()
        self.recorder = nil
    }

    // MARK: Live topology

    /// Replaces the whole set of routes without interrupting audio.
    ///
    /// The alternative — restarting the device — costs about 108 ms of silence
    /// every time a route is added or removed. Here a new graph is built on this
    /// thread, swapped in atomically, and the old one is freed only once the
    /// realtime thread has been seen to complete two cycles past the swap: one
    /// cycle may already have been in flight holding the old pointer.
    @discardableResult
    public func updateRoutes(_ routes: [Route]) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard isRunning, let cell = graphCell, let previous = graph else { return false }

        let rtRoutes = routes.compactMap { route -> RTRoute? in
            guard let source = inputMap[route.source],
                let destination = outputMap[route.destination]
            else { return nil }
            return RTRoute(
                sourceBuffer: source.buffer,
                sourceChannel: source.channel,
                destinationBuffer: destination.buffer,
                destinationChannel: destination.channel,
                gain: route.gain,
                muted: route.isMuted,
                usesIsolatedSource: previous.pointee.routes[0].usesIsolatedSource != 0
                    && route.source == activeRoutes.first?.source)
        }
        guard rtRoutes.count == routes.count else { return false }

        let next = RTGraph.allocate(
            routes: rtRoutes,
            bufferFrames: Int(aggregate?.device?.currentBufferFrameSize ?? 128),
            sampleRate: aggregate?.device?.currentSampleRate ?? 48000)
        // Carry the processing and self-test blocks across: they belong to the
        // engine's lifetime, not to any one graph.
        next.pointee.voiceIsolation = previous.pointee.voiceIsolation
        next.pointee.isolationIsChain = previous.pointee.isolationIsChain
        next.pointee.selftest = previous.pointee.selftest

        _ = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(next))
        graph = next
        activeRoutes = routes

        // A false return means the device is not producing cycles, so nothing
        // can be holding the old graph and it is safe to free anyway.
        _ = yun_rt_cell_wait_for_swap(cell, 200)
        RTGraph.deallocate(previous)
        return true
    }

    // MARK: Live control

    /// Sets a route's gain without interrupting audio.
    ///
    /// The value travels through the lock-free queue and is picked up at the
    /// top of the next cycle, so nothing is rebuilt and nothing blocks.
    @discardableResult
    public func setGain(_ gain: Float, forRouteAt index: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return push(kind: kYunRTCommandSetGain, index: index, value: gain)
    }

    @discardableResult
    public func setMuted(_ muted: Bool, forRouteAt index: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return push(kind: kYunRTCommandSetMute, index: index, value: muted ? 1 : 0)
    }

    private func push(kind: YunRTCommandKind, index: Int, value: Float) -> Bool {
        guard let graph, let commands = graph.pointee.commands,
            index >= 0, index < Int(graph.pointee.routeCount)
        else { return false }
        return yun_rt_queue_push(
            commands,
            YunRTCommand(kind: Int32(kind.rawValue), index: Int32(index), value: value))
    }

    /// Turns on the allocation tripwire. Debug builds only — it hooks the
    /// allocator process-wide.
    public static func enableAllocationTripwire() { yun_rt_tripwire_enable() }

    /// Allocations seen on the IO thread. Any non-zero value is a bug in the
    /// realtime path, not a tuning opportunity.
    public static var allocationViolations: UInt64 { yun_rt_tripwire_violations() }

    /// Grades the loopback capture against what was generated. Valid only while
    /// the route is still up, since stopping frees the capture.
    public func evaluateSelftest() -> SelftestResult? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let selftestBlock else { return nil }
        return RTSelftest.evaluate(selftestBlock)
    }

    /// How much of the capture buffer has been filled, as a fraction.
    public var selftestProgress: Double {
        guard let selftestBlock else { return 0 }
        let capacity = Double(selftestBlock.pointee.captureCapacity)
        guard capacity > 0 else { return 0 }
        return Double(selftestBlock.pointee.captureCount.pointee) / capacity
    }

    /// Clears the latch so a future start may attempt clock locking again.
    public func allowClockLockRetry() {
        stateLock.lock()
        defer { stateLock.unlock() }
        clockLockAbandoned = false
    }

    // MARK: Channel mapping

    /// Works out which IOProc buffer and channel each device channel lands on.
    ///
    /// An aggregate concatenates its members' streams in sub-device order, so
    /// the mapping has to be derived rather than assumed — the Seiren exposes
    /// three channels on one stream, BlackHole sixteen on another.
    private func buildChannelMaps(
        aggregate: AggregateDevice, members: [AudioDevice], taps: [ProcessTap]
    ) throws {
        guard let aggregateDevice = aggregate.device else {
            throw RoutingError.aggregateUnavailable
        }

        let byUID = Dictionary(uniqueKeysWithValues: members.map { ($0.uid, $0) })

        // Taps are appended after the sub-devices on the input side, in the
        // order they were listed, and contribute no output channels. A tap's
        // channels are addressed with its UID as the device reference, so a
        // route can name an application exactly as it names a microphone.
        let inputUIDs = aggregate.subDevices.map(\.uid) + taps.map(\.uid)
        let tapChannels = Dictionary(
            uniqueKeysWithValues: taps.map {
                ($0.uid, Int($0.format?.mChannelsPerFrame ?? 2))
            })

        inputMap = Self.map(
            streams: aggregateDevice.inputStreams,
            orderedUIDs: inputUIDs,
            channelCount: { byUID[$0]?.inputChannels ?? tapChannels[$0] ?? 0 })
        outputMap = Self.map(
            streams: aggregateDevice.outputStreams,
            orderedUIDs: aggregate.subDevices.map(\.uid),
            channelCount: { byUID[$0]?.outputChannels ?? 0 })
    }

    private static func map(
        streams: [AudioStream],
        orderedUIDs: [String],
        channelCount: (String) -> Int
    ) -> [ChannelRef: (buffer: Int32, channel: Int32)] {
        // Walk the aggregate's channels in sub-device order, consuming each
        // stream's channels as we go.
        var result: [ChannelRef: (buffer: Int32, channel: Int32)] = [:]
        var streamIndex = 0
        var channelInStream = 0

        func channelsIn(_ index: Int) -> Int {
            streams[index].currentPhysicalFormat?.channels ?? 0
        }

        for uid in orderedUIDs {
            for channel in 0..<channelCount(uid) {
                while streamIndex < streams.count, channelInStream >= channelsIn(streamIndex) {
                    streamIndex += 1
                    channelInStream = 0
                }
                guard streamIndex < streams.count else { break }
                result[ChannelRef(deviceUID: uid, channel: channel)] =
                    (buffer: Int32(streamIndex), channel: Int32(channelInStream))
                channelInStream += 1
            }
        }
        return result
    }

    // MARK: Introspection

    /// Peak magnitude of each active route since the last read.
    public var routePeaks: [Float] {
        guard let graph else { return [] }
        let count = Int(graph.pointee.routeCount)
        return (0..<count).map { graph.pointee.peaks[$0] }
    }

    /// Number of IO cycles completed. A stalled counter means the device is not
    /// actually pulling audio.
    public var cycleCount: UInt64 {
        graphCell.map { yun_rt_cell_cycles($0) } ?? 0
    }

    /// The clock master's most recent timestamp, read through the cycle counter
    /// as a sequence number so a half-updated pair is never published.
    public var masterClockAnchor: ClockAnchor? {
        guard let graph, isRunning else { return nil }
        let rate = aggregate?.device?.currentSampleRate ?? 0
        guard rate > 0 else { return nil }
        return Self.anchor(from: graph, sampleRate: rate)
    }

    /// Reads the anchor pair using the cycle counter as a sequence number. The
    /// realtime thread writes both values before bumping the counter, so an
    /// unchanged counter either side of the read means the pair is consistent.
    static func anchor(
        from graph: UnsafeMutablePointer<RTGraph>, sampleRate: Double
    ) -> ClockAnchor? {
        for _ in 0..<8 {
            let before = graph.pointee.cycleCounter.pointee
            let sampleTime = graph.pointee.clockSampleTime.pointee
            let hostTime = graph.pointee.clockHostTime.pointee
            let after = graph.pointee.cycleCounter.pointee
            if before == after, hostTime != 0 {
                return ClockAnchor(
                    sampleTime: sampleTime, hostTime: hostTime, sampleRate: sampleRate)
            }
        }
        return nil
    }

    /// True when the destination is our own driver and it has confirmed that it
    /// is following the master's clock.
    public var isClockLocked: Bool { clockPublisher?.isLocked ?? false }

    /// How far the master's crystal is from its nominal rate, as a ratio.
    public var measuredRateRatio: Double { clockPublisher?.rateRatio ?? 1.0 }

    public var pathQuality: PathQuality? {
        guard let aggregate, let device = aggregate.device else { return nil }
        let drifted = aggregate.driftCorrectedUIDs
        let processing = isolationUnit != nil || effectChain != nil
        return PathQuality(
            // Nothing is being drift-corrected, nothing is processing the
            // signal, and where the first was only true because the driver
            // locks its own clock, the lock is confirmed to be holding. These
            // are facts we configured or read back — but "nothing is configured
            // to alter the signal" is still weaker than "the samples came back
            // identical", which is what --selftest is for.
            isBitExact: drifted.isEmpty && !processing
                && (requiresClockLock ? isClockLocked : true),
            hasProcessing: processing,
            isClockLocked: isClockLocked,
            measuredRateRatio: measuredRateRatio,
            driftCorrectedDeviceUIDs: drifted,
            bufferFrames: Int(device.currentBufferFrameSize ?? 0),
            sampleRate: device.currentSampleRate ?? 0)
    }
}

public enum RoutingError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case channelNotFound(ChannelRef, isInput: Bool)
    case noCommonSampleRate
    case aggregateUnavailable
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)

    public var description: String {
        switch self {
        case let .deviceNotFound(uid):
            "no audio device with UID \(uid)"
        case let .channelNotFound(ref, isInput):
            "\(isInput ? "input" : "output") channel \(ref.channel) of \(ref.deviceUID) is not part of the aggregate"
        case .noCommonSampleRate:
            "the selected devices share no sample rate"
        case .aggregateUnavailable:
            "the aggregate device could not be inspected after creation"
        case let .ioProcFailed(status):
            "AudioDeviceCreateIOProcID failed with \(fourCharDescription(status))"
        case let .startFailed(status):
            "AudioDeviceStart failed with \(fourCharDescription(status))"
        }
    }
}
