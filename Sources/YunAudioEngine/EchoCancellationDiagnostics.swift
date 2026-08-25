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
        case built
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
                    _ = bridge
                    return .built
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

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Outcome = .didNotReturn
        func record(_ value: Outcome) { lock.withLock { stored = value } }
        var outcome: Outcome { lock.withLock { stored } }
    }
}
