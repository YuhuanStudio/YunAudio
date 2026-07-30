import Foundation

/// A preallocated handover between two effect paths.
///
/// Building and owning the two paths remains a control-thread job. This object
/// only schedules their already-rendered mono buffers: the old path remains
/// audible while the new path fills its latency. Equal-latency paths use a
/// twenty-millisecond linear handover; a latency change uses a bounded splice
/// because mixing two different points in correlated audio can cancel them.
/// Raw audio is simply a path whose latency is zero, so raw-to-stage and
/// stage-to-raw use the same machinery.
///
/// Gain curves and storage are prepared at construction. `process` allocates
/// nothing and is therefore suitable for the IO thread.
final class EffectTransition {
    static let fadeSeconds = 0.020

    let oldLatencyFrames: Int
    let newLatencyFrames: Int
    let warmupFrames: Int
    let fadeFrames: Int

    private let progress: UnsafeMutablePointer<Float>
    private let changesLatency: Bool
    private let searchFrames: Int
    private let fallbackFrames: Int
    private var warmupPosition = 0
    private var fadePosition = 0
    private var previousOld: Float = 0
    private var previousNew: Float = 0
    private var hasPreviousOld = false
    /// Tracked apart from the old path's history, because during warm-up the new
    /// path has none worth having. See `processLatencyChange`.
    private var hasPreviousNew = false
    private var fallbackStartFrame: Int?
    private var mismatchComplete = false

    private(set) var spliceFrame: Int?
    var isComplete: Bool {
        changesLatency ? mismatchComplete : fadePosition == fadeFrames
    }
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
        changesLatency = self.oldLatencyFrames != self.newLatencyFrames
        fallbackFrames = min(
            fadeFrames,
            max(1, Int((sampleRate * 0.005).rounded())))
        searchFrames = fadeFrames - fallbackFrames

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
                let oldSample = sanitisedAudioSample(old[frame])
                output[frame] = oldSample
                previousOld = oldSample
                hasPreviousOld = true
            }
            warmupPosition += count
            offset = count
        }

        if changesLatency {
            processLatencyChange(
                old: old, new: new, output: output,
                offset: offset, frames: frames)
            return
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

    /// Finds a low-error sample boundary before falling back to a de-click.
    ///
    /// A continuous fade between two versions of a correlated signal whose
    /// latencies differ must pass through equal gains. At a half-cycle offset
    /// that point is silence, whatever gain curve is used. A splice does not
    /// pretend the time shift disappeared: it moves that unavoidable boundary
    /// to a sample where the output step is no larger than either path's local
    /// step. If no such boundary arrives in fifteen milliseconds, the remaining
    /// five milliseconds lower the old path to zero before raising the new one,
    /// so unlike a crossfade the two phases are never added together.
    @inline(__always)
    private func processLatencyChange(
        old: UnsafePointer<Float>, new: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>, offset: Int, frames: Int
    ) {
        var cursor = offset

        if spliceFrame != nil {
            while cursor < frames {
                output[cursor] = sanitisedAudioSample(new[cursor])
                cursor += 1
            }
            return
        }

        if fallbackStartFrame == nil {
            while cursor < frames {
                let absoluteFrame = processedFrames + cursor
                let searchPosition = absoluteFrame - warmupFrames
                if searchPosition >= searchFrames {
                    fallbackStartFrame = absoluteFrame
                    break
                }

                let oldSample = sanitisedAudioSample(old[cursor])
                let newSample = sanitisedAudioSample(new[cursor])
                if hasPreviousOld {
                    // The new path's own step counts only once it has produced
                    // two real samples. Seeded from the warm-up region it was
                    // the step out of the cold path's silence — up to full
                    // scale — which made this test permissive enough to splice
                    // anywhere: enabling a cold chain on a 997 Hz tone stepped
                    // 0.295 where the tone itself steps 0.052.
                    var localStep = abs(oldSample - previousOld)
                    if hasPreviousNew {
                        localStep = max(localStep, abs(newSample - previousNew))
                    }
                    let seam = abs(newSample - previousOld)
                    if seam <= localStep * 1.1 + 1e-6 {
                        spliceFrame = absoluteFrame
                        mismatchComplete = true
                        output[cursor] = newSample
                        cursor += 1
                        while cursor < frames {
                            output[cursor] = sanitisedAudioSample(new[cursor])
                            cursor += 1
                        }
                        return
                    }
                }
                output[cursor] = oldSample
                previousOld = oldSample
                previousNew = newSample
                hasPreviousOld = true
                hasPreviousNew = true
                cursor += 1
            }
        }

        guard let fallbackStartFrame else { return }
        while cursor < frames {
            let absoluteFrame = processedFrames + cursor
            let fallbackPosition = absoluteFrame - fallbackStartFrame
            let oldSample = sanitisedAudioSample(old[cursor])
            let newSample = sanitisedAudioSample(new[cursor])
            output[cursor] = fallbackSample(
                old: oldSample, new: newSample,
                at: fallbackPosition)
            if fallbackPosition >= fallbackFrames - 1 {
                mismatchComplete = true
            }
            cursor += 1
        }
    }

    @inline(__always)
    private func fallbackSample(old: Float, new: Float, at frame: Int) -> Float {
        if frame < 0 { return old }
        if frame >= fallbackFrames { return new }
        if fallbackFrames == 1 { return new }

        let fadeOutFrames = max(1, fallbackFrames / 2)
        if frame < fadeOutFrames {
            guard fadeOutFrames > 1 else { return old }
            let amount = Float(frame) / Float(fadeOutFrames - 1)
            return old * (1 - amount)
        }

        let fadeInFrames = fallbackFrames - fadeOutFrames
        guard fadeInFrames > 1 else { return new }
        let amount = Float(frame - fadeOutFrames) / Float(fadeInFrames - 1)
        return new * amount
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
        if changesLatency {
            if let spliceFrame {
                return frame < spliceFrame ? safeOld : safeNew
            }
            if let fallbackStartFrame {
                return fallbackSample(
                    old: safeOld, new: safeNew,
                    at: frame - fallbackStartFrame)
            }
            return safeOld
        }
        let fade = frame - warmupFrames
        if fade >= fadeFrames { return safeNew }
        return safeOld + (safeNew - safeOld) * progress[fade]
    }
}
