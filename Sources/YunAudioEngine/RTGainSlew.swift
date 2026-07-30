/// A fixed-size gain ramp for the realtime path.
///
/// The control queue changes a target at a callback boundary, but the audible
/// value moves one sample at a time. Keeping the state as scalars means a graph
/// can own or copy it without ARC, allocation or a lock on the IO thread.
struct RTGainSlew: Sendable, Equatable {
    private(set) var current: Float
    private(set) var target: Float
    private(set) var linearStep: Float
    private(set) var remainingFrames: Int32

    init(_ value: Float = 1) {
        let finite = value.isFinite ? value : 0
        current = finite
        target = finite
        linearStep = 0
        remainingFrames = 0
    }

    /// Starts a linear ramp from the value reached so far.
    ///
    /// Retargeting does not remember the ramp's original start. A fader that
    /// moves again half way through therefore continues from the sample the
    /// listener just heard instead of jumping back to an obsolete value.
    @inline(__always)
    mutating func retargetLinear(to value: Float, frames: Int) {
        guard value.isFinite else { return }
        guard value != target || (remainingFrames == 0 && value != current) else { return }
        target = value
        let effectiveFrames = min(max(frames, 0), Int(Int32.max))
        guard effectiveFrames > 0, value != current else {
            current = value
            linearStep = 0
            remainingFrames = 0
            return
        }
        if effectiveFrames == 1 {
            // The first `nextLinear` assigns the target. Avoid calculating a
            // difference between opposite Float extremes merely to discard it.
            linearStep = 0
        } else {
            // Two finite Floats can have a difference wider than Float. Double
            // holds the complete range and keeps the ramp state finite.
            linearStep = Float(
                (Double(value) - Double(current)) / Double(effectiveFrames))
        }
        remainingFrames = Int32(effectiveFrames)
    }

    /// Returns the next sample's gain.
    ///
    /// The last frame is assigned rather than accumulated. That makes a mute
    /// reach exact zero and prevents floating-point drift across many small
    /// retargets.
    @inline(__always)
    mutating func nextLinear() -> Float {
        guard remainingFrames > 0 else { return current }
        remainingFrames -= 1
        if remainingFrames == 0 {
            current = target
            linearStep = 0
        } else {
            let candidate = Double(current) + Double(linearStep)
            if target > current {
                current = Float(min(candidate, Double(target)))
            } else {
                current = Float(max(candidate, Double(target)))
            }
        }
        return current
    }

    /// Moves time forward when a route has no buffer in this callback.
    ///
    /// A device returning after a short interruption should hear the gain that
    /// wall-clock time reached, not the beginning of a fade postponed until
    /// audio happened to become available again.
    @inline(__always)
    mutating func advanceLinear(frames: Int) {
        guard frames > 0, remainingFrames > 0 else { return }
        var count = min(frames, Int(remainingFrames))
        // Deliberately repeat the same addition as `nextLinear`. Multiplying
        // the step by `count` changes Float rounding, so the gain after a
        // missing buffer would differ from the gain after a rendered one.
        while count > 0 {
            _ = nextLinear()
            count -= 1
        }
    }

    /// Advances a moving target with a per-sample one-pole coefficient.
    ///
    /// Ducking uses this form because its target can change every callback and
    /// its existing 80/600 ms attack and release are time constants rather
    /// than fixed completion deadlines.
    @inline(__always)
    mutating func nextOnePole(towards value: Float, coefficient: Float) -> Float {
        guard value.isFinite, coefficient.isFinite, coefficient >= 0, coefficient <= 1
        else { return current }
        target = value
        remainingFrames = 0
        linearStep = 0
        // Convex form rather than `value + (current - value) * coefficient`:
        // the subtraction overflows for opposite finite Float extremes.
        let next = current * coefficient + value * (1 - coefficient)
        if next.isFinite {
            current = next
        } else {
            current = Float(
                Double(current) * Double(coefficient)
                    + Double(value) * Double(1 - coefficient))
        }
        return current
    }
}
