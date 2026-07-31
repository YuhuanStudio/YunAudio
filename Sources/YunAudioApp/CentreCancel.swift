import AVFoundation
import Accelerate

/// Taking the lead vocal out of a stereo mix, as far as that can honestly be done.
///
/// The second button every KTV machine has, after the key. What it does is not
/// vocal separation: a lead vocal is almost always mixed dead centre, which
/// means it is the part of the signal that is identical in both channels, and
/// subtracting one channel from the other removes everything that is. So does
/// the kick, the snare and the bass, which are also centred — that is the
/// trade, it is inherent to the method, and the interface says so rather than
/// promising an instrumental.
///
/// Kept as a pure function over interleaved-by-channel buffers so the trade can
/// be asserted: a centred signal really does cancel, a signal only in one
/// channel really does survive, and the result does not clip on material where
/// the two channels are already far apart.
enum CentreCancel {

    /// How much of the centre to remove, 0 to 1.
    ///
    /// Not a switch, because the honest setting is rarely "all of it": at 1 the
    /// bass goes with the voice and the backing track hollows out. Somebody
    /// singing over it wants the voice down far enough to lead without the
    /// track falling apart.
    static let defaultAmount: Float = 0.85

    /// Mid/side with the mid attenuated, in place.
    ///
    /// - Parameters:
    ///   - left: Left channel samples, modified.
    ///   - right: Right channel, modified.
    ///   - amount: 0 leaves the mix alone; 1 removes everything both channels
    ///     agree on.
    static func apply(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int,
        amount: Float
    ) {
        guard frames > 0 else { return }
        let amount = max(0, min(1, amount))
        guard amount > 0 else { return }
        for frame in 0..<frames {
            let l = left[frame]
            let r = right[frame]
            // Mid and side, then the mid put back at what is left of it. The
            // arithmetic is the same as `l - amount * mid`, written this way
            // because the two halves are what the comment above is about.
            let mid = (l + r) * 0.5
            let keep = mid * (1 - amount)
            left[frame] = (l - mid) + keep
            right[frame] = (r - mid) + keep
        }
    }

    /// The same, for a single interleaved stereo block.
    static func apply(
        interleaved samples: UnsafeMutablePointer<Float>, frames: Int, amount: Float
    ) {
        guard frames > 0 else { return }
        let amount = max(0, min(1, amount))
        guard amount > 0 else { return }
        for frame in 0..<frames {
            let l = samples[frame * 2]
            let r = samples[frame * 2 + 1]
            let mid = (l + r) * 0.5
            let keep = mid * (1 - amount)
            samples[frame * 2] = (l - mid) + keep
            samples[frame * 2 + 1] = (r - mid) + keep
        }
    }

    /// What a mono file can expect, which is nothing.
    ///
    /// There is no side channel to keep, so cancelling the centre cancels the
    /// whole recording. The player refuses rather than playing silence and
    /// leaving somebody to work out why.
    static func isPossible(channels: AVAudioChannelCount) -> Bool { channels >= 2 }
}
