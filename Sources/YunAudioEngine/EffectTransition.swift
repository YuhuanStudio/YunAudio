import Foundation

/// A preallocated handover between two effect paths.
///
/// Building and owning the two paths remains a control-thread job. This object
/// only schedules their already-rendered mono buffers: the old path remains
/// audible while the new path fills its latency, then a twenty-millisecond
/// equal-power fade hands one to the other. Raw audio is simply a path whose
/// latency is zero, so raw-to-stage and stage-to-raw use the same machinery.
///
/// Gain curves are calculated at construction. `process` performs only loads,
/// multiplies and stores, and is therefore suitable for the IO thread.
final class EffectTransition {
    static let fadeSeconds = 0.020

    let oldLatencyFrames: Int
    let newLatencyFrames: Int
    let warmupFrames: Int
    let fadeFrames: Int

    private let progress: UnsafeMutablePointer<Float>
    private var warmupPosition = 0
    private var fadePosition = 0

    var isComplete: Bool { fadePosition == fadeFrames }
    private(set) var processedFrames = 0

    init(
        sampleRate: Double, oldLatencyFrames: Int,
        newLatencyFrames: Int
    ) {
        self.oldLatencyFrames = max(0, oldLatencyFrames)
        self.newLatencyFrames = max(0, newLatencyFrames)
        // A newly-created stage starts with empty history regardless of how
        // much latency the old path had. Keep the known-good path audible until
        // the newcomer can produce a real sample.
        warmupFrames = self.newLatencyFrames
        fadeFrames = max(1, Int((sampleRate * Self.fadeSeconds).rounded()))

        progress = .allocate(capacity: fadeFrames)
        for frame in 0..<fadeFrames {
            // The first frame is still exactly the old path and the final frame
            // exactly the new one. These are two versions of the same source,
            // not independent signals: an equal-power curve makes identical
            // paths 3.01 dB louder at the midpoint and then hard-clips them.
            // Linear interpolation keeps every output between its two inputs.
            let value =
                fadeFrames == 1 ? Float(1) : Float(frame) / Float(fadeFrames - 1)
            (progress + frame).initialize(to: value)
        }
    }

    deinit {
        progress.deinitialize(count: fadeFrames)
        progress.deallocate()
    }

    /// Writes one transition block.
    ///
    /// Both input pointers must contain `frames` mono samples. They may alias
    /// `output`; each pair is loaded before that output sample is written.
    func process(
        old: UnsafePointer<Float>, new: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>, frames: Int
    ) {
        guard frames > 0 else { return }
        defer { processedFrames += frames }
        var offset = 0

        if warmupPosition < warmupFrames {
            let count = min(frames, warmupFrames - warmupPosition)
            for frame in 0..<count {
                output[frame] = sanitisedAudioSample(old[frame])
            }
            warmupPosition += count
            offset = count
        }

        if offset < frames, fadePosition < fadeFrames {
            let count = min(frames - offset, fadeFrames - fadePosition)
            for frame in 0..<count {
                let input = offset + frame
                let oldSample = sanitisedAudioSample(old[input])
                let newSample = sanitisedAudioSample(new[input])
                let amount = progress[fadePosition + frame]
                output[input] =
                    oldSample + (newSample - oldSample) * amount
            }
            fadePosition += count
            offset += count
        }

        if offset < frames {
            for frame in offset..<frames {
                output[frame] = sanitisedAudioSample(new[frame])
            }
        }
    }

    /// Mixes one pair at an absolute frame on this handover's timeline.
    ///
    /// The graph uses this for paths that bypassed the effect chain. Calling
    /// `process` advances the shared timeline once; every aligned route then
    /// asks for the gains at that same block's frame without advancing it
    /// again.
    @inline(__always)
    func sample(old: Float, new: Float, at frame: Int) -> Float {
        let safeOld = sanitisedAudioSample(old)
        let safeNew = sanitisedAudioSample(new)
        if frame < warmupFrames { return safeOld }
        let fade = frame - warmupFrames
        if fade >= fadeFrames { return safeNew }
        return safeOld + (safeNew - safeOld) * progress[fade]
    }
}
