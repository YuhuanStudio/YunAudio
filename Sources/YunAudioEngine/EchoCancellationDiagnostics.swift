import Foundation
import YunAudioHAL

/// Building the echo canceller the way a route does, one layer at a time.
///
/// Turning echo cancellation on and pressing Start wedges Core Audio's device
/// path — reproduced on demand, on a clean machine, in under four seconds, from
/// a state the health probe calls clean. Six weaker constructions were tried
/// first and all of them built without incident: the voice-processing unit
/// alone, the unit with a route already running, the whole bridge alone, the
/// bridge right after this process moved both devices' nominal rates, the
/// bridge with a route running, and the bridge with the 128-frame slice a route
/// actually asks for rather than the probe's own 512.
///
/// What is left between those and the route is here: the route constructs on a
/// bounded lane, with a cancellation context, holding a graph admission across
/// the whole thing. This lets each of those be added on its own.
///
/// It lives in the engine rather than the command-line tool because every one
/// of them is internal, and a diagnostic that has to be reimplemented to reach
/// what it is diagnosing is measuring its own reimplementation.
public enum EchoCancellationDiagnostics {

    /// Which of the route's wrappings to reproduce.
    public struct Layers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Construct on `BoundedAudioUnitConstructionLane.echoCancellation`,
        /// which means on its worker thread rather than the caller's.
        public static let lane = Layers(rawValue: 1 << 0)
        /// Hold a `BoundedAudioUnitDisposer` graph admission across it.
        public static let graphAdmission = Layers(rawValue: 1 << 1)
        /// Pass the lane's cancellation context down, as the route does.
        public static let constructionContext = Layers(rawValue: 1 << 2)
    }

    public enum Outcome: Sendable, Equatable {
        /// Built, and taken down again — with what the teardown said.
        case built(String)
        case refused(String)
        /// The construction did not return inside the budget. This is the
        /// fault: a synchronous call that never comes back, leaving a thread
        /// inside it for the life of the process.
        case didNotReturn
    }

    /// Builds one bridge with the named layers and throws it away.
    ///
    /// Blocks for at most `budget`. The construction is always run on a thread
    /// this function owns, so `didNotReturn` costs one leaked thread and not
    /// the caller.
    public static func build(
        microphoneUID: String,
        speakerUID: String,
        sampleRate: Double = 48_000,
        sliceFrames: Int = 128,
        layers: Layers,
        budget: TimeInterval = 15
    ) -> Outcome {
        let settings = EchoCancellationSettings(speakerUID: speakerUID)
        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()

        let work: @Sendable () -> Void = {
            // Acquired before the lane, exactly as the route does it. Bound
            // by `let` because the lane's closure has to be `@Sendable` and a
            // captured `var` is not.
            let admission: BoundedAudioUnitDisposer.GraphAdmission?
            if layers.contains(.graphAdmission) {
                guard
                    let acquired = BoundedAudioUnitDisposer.shared
                        .acquireGraphAdmissionAfterDraining(waitingUpTo: 2.25)
                else {
                    box.record(.refused("no graph admission"))
                    done.signal()
                    return
                }
                admission = acquired
            } else {
                admission = nil
            }
            defer { admission?.release() }

            let make: @Sendable (AudioUnitConstructionContext?) -> Outcome = { context in
                do {
                    let bridge = try EchoCancellationBridge(
                        microphoneUID: microphoneUID, settings: settings,
                        routerSampleRate: sampleRate, maximumFrames: sliceFrames,
                        constructionContext: layers.contains(.constructionContext)
                            ? context : nil,
                        graphAdmission: admission)
                    // Taken down here rather than left to a deinitialiser.
                    //
                    // The first version of this discarded the bridge and probed
                    // the server, and read "wedged" — but a live canceller
                    // holding the microphone is a reason for a new aggregate to
                    // be refused that has nothing to do with the fault. The
                    // question is whether the server is still wrong *after*
                    // this thing has gone, and that needs the teardown to have
                    // happened and been waited for.
                    let teardown = bridge.stop()
                    return .built(String(describing: teardown))
                } catch {
                    return .refused(String(describing: error))
                }
            }

            if layers.contains(.lane) {
                let result: AudioUnitLaneResult<Outcome> =
                    BoundedAudioUnitConstructionLane.echoCancellation.perform(
                        timeout: AudioUnitConstructionBudget.echoCancellation
                    ) { context in make(context) }
                switch result {
                case .completed(let outcome): box.record(outcome)
                case .timedOut: box.record(.didNotReturn)
                case .refused: box.record(.refused("the lane refused"))
                case .superseded: box.record(.refused("superseded"))
                }
            } else {
                box.record(make(nil))
            }
            done.signal()
        }

        let thread = Thread { work() }
        thread.name = "com.yuhuanstudio.yunaudio.echo-diagnostic"
        thread.start()
        guard done.wait(timeout: .now() + budget) == .success else { return .didNotReturn }
        return box.outcome
    }

    /// Whether a route's aggregate can be created while the canceller is live.
    ///
    /// This is the ordering `startAttempt` uses: the bridge is constructed
    /// first, and the aggregate the route runs on is built after it, with the
    /// canceller already holding the microphone. Six combinations of the
    /// route's wrappings all built and tore down with the server left healthy,
    /// so the construction is not the fault — but a probe taken while the
    /// bridge was still alive read "wedged", and that is this question.
    ///
    /// Returns what happened at each step, in order, for printing.
    public static func aggregateWhileCancelling(
        microphoneUID: String,
        speakerUID: String,
        sampleRate: Double = 48_000,
        sliceFrames: Int = 128,
        destinationOnly: Bool = false,
        bufferFrames: Int? = nil,
        started: Bool = false,
        driftCorrected: Bool = false,
        budget: TimeInterval = 15
    ) -> [String] {
        var lines: [String] = []
        let settings = EchoCancellationSettings(speakerUID: speakerUID)
        let bridge: EchoCancellationBridge
        do {
            bridge = try EchoCancellationBridge(
                microphoneUID: microphoneUID, settings: settings,
                routerSampleRate: sampleRate, maximumFrames: sliceFrames)
            lines.append("canceller built and kept alive")
            // Started, when asked for — which is what the route does, and what
            // ten probes before this one did not.
            //
            // `startAttempt` builds the canceller, builds the aggregate, builds
            // the chain, and then calls `bridge.start()` immediately before
            // `AudioDeviceCreateIOProcID`. Every earlier probe stopped at
            // "built", so the one state the route is actually in when it hangs
            // — a *running* voice-processing unit holding the microphone —
            // had never been reproduced.
            if started {
                lines.append(
                    bridge.start()
                        ? "canceller started" : "canceller would not start")
            }
        } catch {
            return ["canceller refused: \(String(describing: error))"]
        }
        defer { _ = bridge.stop() }

        // The same shape a route builds: an input and an output, drift
        // corrected between them.
        let devices = (try? AudioDevices.all()) ?? []
        // The shape a route builds *with cancellation on* is not a pair.
        //
        // `members = cancelsEcho ? [destination] + extras : [source, destination]`
        // — the microphone leaves the aggregate, because the canceller has it.
        // So the route's aggregate is the destination alone, and on this
        // project's own setup that destination is the virtual driver. The
        // stage trace puts the hang after "create the aggregate" (8 ms) and
        // before `AudioDeviceStart`, which leaves exactly one call: opening an
        // IOProc on that one-member aggregate.
        if destinationOnly {
            guard
                let destination = devices.first(where: {
                    $0.uid == ClockAnchorPublisher.driverDeviceUID
                }) ?? devices.first(where: { $0.transport.isVirtual && $0.hasOutput })
            else {
                lines.append("no virtual destination to build a one-member aggregate from")
                return lines
            }
            let done = DispatchSemaphore(value: 0)
            let box = OutcomeBox()
            let thread = Thread {
                do {
                    let aggregate = try AggregateDevice(
                        name: "YunAudio ordering probe",
                        subDevices: [
                            // Drift-corrected against itself, which is what
                            // the route asks for: with the canceller holding
                            // the microphone the destination is the only member
                            // left, `follower()` marks every member as one, and
                            // the clock master is that same device.
                            AggregateDevice.SubDevice(
                                uid: destination.uid, driftCompensation: driftCorrected)
                        ],
                        clockMasterUID: destination.uid)
                    lines.append("aggregate of \(destination.name) alone: created")
                    // What the route does between creating it and opening it,
                    // and what no probe before this one did: ask the aggregate
                    // for the route's buffer size. A one-member aggregate of a
                    // virtual driver being told to use 128 frames and then
                    // opened is the last untried difference.
                    if let bufferFrames {
                        do {
                            try aggregate.setBufferFrameSize(UInt32(bufferFrames))
                            lines.append("buffer set to \(bufferFrames) frames")
                        } catch {
                            lines.append("buffer refused: \(String(describing: error))")
                        }
                    }
                    let opened = AudioServerHealth.openAndClose(aggregate.id)
                    _ = aggregate.destroy()
                    box.record(opened ? .built("opened") : .refused("would not open"))
                } catch {
                    box.record(.refused(String(describing: error)))
                }
                done.signal()
            }
            thread.name = "com.yuhuanstudio.yunaudio.ordering-probe"
            thread.start()
            if done.wait(timeout: .now() + budget) == .success {
                switch box.outcome {
                case .built(let how): lines.append("IOProc on it: \(how)")
                case .refused(let why): lines.append("IOProc on it: \(why)")
                case .didNotReturn: lines.append("IOProc on it: DID NOT RETURN")
                }
            } else {
                lines.append("IOProc on it: DID NOT RETURN — this is the wedge")
            }
            return lines
        }

        // Two *different* devices. On a machine whose only endpoint carries
        // both directions — a virtual machine's, for one — asking for the same
        // UID twice is refused by the aggregate's own validation, and the probe
        // then reports its own mistake as a finding.
        guard let input = devices.first(where: \.hasInput),
            let output = devices.first(where: {
                $0.hasOutput && $0.uid != input.uid && !$0.transport.isVirtual
            }) ?? devices.first(where: { $0.hasOutput && $0.uid != input.uid })
        else {
            lines.append("no pair of distinct devices to build an aggregate from")
            return lines
        }

        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        let thread = Thread {
            do {
                let aggregate = try AggregateDevice(
                    name: "YunAudio ordering probe",
                    subDevices: [
                        AggregateDevice.SubDevice(uid: input.uid, driftCompensation: false),
                        AggregateDevice.SubDevice(uid: output.uid, driftCompensation: true),
                    ],
                    clockMasterUID: input.uid)
                let opened = AudioServerHealth.openAndClose(aggregate.id)
                _ = aggregate.destroy()
                box.record(opened ? .built("opened") : .refused("would not open"))
            } catch {
                box.record(.refused(String(describing: error)))
            }
            done.signal()
        }
        thread.name = "com.yuhuanstudio.yunaudio.ordering-probe"
        thread.start()
        if done.wait(timeout: .now() + budget) == .success {
            switch box.outcome {
            case .built(let how): lines.append("aggregate while cancelling: \(how)")
            case .refused(let why): lines.append("aggregate while cancelling: \(why)")
            case .didNotReturn: lines.append("aggregate while cancelling: DID NOT RETURN")
            }
        } else {
            lines.append("aggregate while cancelling: DID NOT RETURN — this is the wedge")
        }
        return lines
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Outcome = .didNotReturn
        func record(_ value: Outcome) { lock.withLock { stored = value } }
        var outcome: Outcome { lock.withLock { stored } }
    }
}
