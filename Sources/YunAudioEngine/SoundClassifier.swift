import AVFoundation
import Foundation
import SoundAnalysis

/// What the microphone is actually hearing, from Apple's on-device sound model.
///
/// `SNClassifySoundRequest(classifierIdentifier: .version1)` is a three-hundred
/// class audio classifier that ships with the system, runs on the device and
/// costs nothing. It is normally used for accessibility — recognising a smoke
/// alarm or a doorbell — and nothing in this category has thought to point it
/// at a microphone's own signal.
///
/// Two things become possible with it that are not possible without. Automatic
/// levelling can be told to move only while a person is speaking, which is the
/// single difference between a leveller that helps and the AGC everybody turns
/// off. And the interface can say what is in the signal — that there is typing
/// under the voice, or that the room has a fan in it — which is a diagnosis
/// rather than a meter reading.
public final class SoundClassifier: @unchecked Sendable {

    /// What the model heard, reduced to the handful of things worth acting on.
    public enum Verdict: String, Sendable, CaseIterable {
        case speech
        case typing
        case music
        case noise
        case quiet

        public var isSpeech: Bool { self == .speech }

        /// Class labels from the version-1 taxonomy that map onto each verdict.
        ///
        /// The model's own labels are far finer than anything useful here — it
        /// separates "speech" from "singing" from "shout" — so they are folded
        /// down. Prefix matching rather than equality because the taxonomy uses
        /// compound labels like `keyboard_typing` and `speech_synthesizer`.
        static let prefixes: [(Verdict, [String])] = [
            (.speech, ["speech", "conversation", "narration", "shout", "yell", "whisper"]),
            (.typing, ["typing", "keyboard", "computer_keyboard", "mouse_click", "writing"]),
            (.music, ["music", "singing", "instrument", "guitar", "piano", "drum"]),
            (
                .noise,
                [
                    "noise", "hum", "fan", "air_conditioning", "vacuum", "traffic",
                    "wind", "rustling", "static",
                ]
            ),
        ]
    }

    /// The most recent verdict and how sure the model was.
    public private(set) var verdict: Verdict = .quiet
    public private(set) var confidence: Double = 0
    /// The model's own top label, unfolded. Worth showing: "keyboard_typing" is
    /// more useful to somebody debugging their setup than "typing".
    public private(set) var label: String = ""

    /// True when speech is present with enough confidence to act on.
    ///
    /// Deliberately not the same threshold as the display. Showing a low
    /// confidence guess costs nothing; moving somebody's gain on one costs
    /// them their level.
    public var hearsSpeech: Bool { verdict == .speech && confidence >= 0.5 }

    private let analyser: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let observer = Observer()
    private var sampleTime: AVAudioFramePosition = 0
    /// The model wants its own window; feeding it a hundred tiny buffers per
    /// second is wasted work, so samples are accumulated first.
    private var pending: [Float] = []
    private let windowFrames: Int

    /// Bridges the delegate callbacks, which arrive on the analyser's queue,
    /// back onto plain stored values.
    private final class Observer: NSObject, SNResultsObserving {
        let lock = NSLock()
        var identifier = ""
        var confidence: Double = 0

        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let classification = result as? SNClassificationResult,
                let best = classification.classifications.first
            else { return }
            lock.lock()
            identifier = best.identifier
            confidence = best.confidence
            lock.unlock()
        }

        // A failure here is not worth surfacing as an error: the classifier is
        // an enhancement, and levelling falls back to holding still.
        func request(_ request: any SNRequest, didFailWithError error: any Error) {}
        func requestDidComplete(_ request: any SNRequest) {}
    }

    public init?(sampleRate: Double) {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return nil }
        self.format = format
        analyser = SNAudioStreamAnalyzer(format: format)
        // Half a second. The model's own window is shorter, but classifying
        // twice a second is plenty for something a person reads, and it keeps
        // the work off the poll that feeds it.
        windowFrames = Int(sampleRate * 0.5)
        pending.reserveCapacity(windowFrames)

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // The model reports on overlapping windows; overlap costs CPU for
            // a display that changes twice a second anyway.
            request.overlapFactor = 0
            try analyser.add(request, withObserver: observer)
        } catch {
            return nil
        }
    }

    /// Feeds samples. Classifies whenever a window has accumulated.
    public func add(_ samples: UnsafePointer<Float>, count: Int) {
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        guard pending.count >= windowFrames else { return }

        let frames = pending.count
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let channel = buffer.floatChannelData
        else {
            pending.removeAll(keepingCapacity: true)
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        pending.withUnsafeBufferPointer {
            channel[0].update(from: $0.baseAddress!, count: frames)
        }
        pending.removeAll(keepingCapacity: true)

        analyser.analyze(buffer, atAudioFramePosition: sampleTime)
        sampleTime += AVAudioFramePosition(frames)
        refresh(rootMeanSquare: rootMeanSquare(of: buffer, frames: frames))
    }

    private func rootMeanSquare(of buffer: AVAudioPCMBuffer, frames: Int) -> Float {
        guard let channel = buffer.floatChannelData, frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            let sample = channel[0][index]
            sum += sample * sample
        }
        return (sum / Float(frames)).squareRoot()
    }

    private func refresh(rootMeanSquare level: Float) {
        observer.lock.lock()
        let identifier = observer.identifier
        let confidence = observer.confidence
        observer.lock.unlock()

        label = identifier
        // Below about −60 dBFS there is nothing there, and the model will still
        // name its best guess with real confidence. Reporting that as "speech"
        // would be worse than saying nothing.
        guard level > 0.001 else {
            verdict = .quiet
            self.confidence = 0
            return
        }
        self.confidence = confidence
        verdict = Self.fold(identifier)
    }

    /// Folds a model label onto one of the verdicts.
    static func fold(_ identifier: String) -> Verdict {
        let lowered = identifier.lowercased()
        for (verdict, prefixes) in Verdict.prefixes {
            // Contains rather than hasPrefix: the taxonomy puts the noun last
            // as often as first — `finger_snapping`, `computer_keyboard`.
            if prefixes.contains(where: { lowered.contains($0) }) { return verdict }
        }
        return .noise
    }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        verdict = .quiet
        confidence = 0
        label = ""
    }
}
