import Foundation

/// One fixed-duration measurement of a physical input channel.
///
/// Peak and RMS are kept in linear full-scale units so callers can choose how
/// to present silence. `activeFrames` makes a low signal distinguishable from
/// a buffer which was exactly zero throughout.
public struct InputChannelSignalWindow: Sendable, Equatable {
    public let firstFrame: Int
    public let frameCount: Int
    public let peak: Float
    public let rms: Float
    public let activeFrames: Int

    public var isExactlySilent: Bool { activeFrames == 0 }
}

/// Numerical evidence for a direct, multi-channel device capture.
///
/// This analyser deliberately knows nothing about speech or pitch. A swept
/// note is evidence only when the samples themselves remain present; labelling
/// them as voice first would reintroduce the very gate this diagnostic exists
/// to rule out.
public enum InputChannelSignalEvidence {
    public static func windows(
        samples: [Float], windowFrames: Int
    ) -> [InputChannelSignalWindow] {
        guard windowFrames > 0, !samples.isEmpty else { return [] }

        var result: [InputChannelSignalWindow] = []
        result.reserveCapacity((samples.count + windowFrames - 1) / windowFrames)
        var first = 0
        while first < samples.count {
            let end = min(first + windowFrames, samples.count)
            var peak: Float = 0
            var energy: Double = 0
            var activeFrames = 0
            for index in first..<end {
                let sample = samples[index].isFinite ? samples[index] : 0
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                energy += Double(sample) * Double(sample)
                if magnitude > 0 { activeFrames += 1 }
            }
            let count = end - first
            result.append(
                InputChannelSignalWindow(
                    firstFrame: first,
                    frameCount: count,
                    peak: peak,
                    rms: count > 0 ? Float((energy / Double(count)).squareRoot()) : 0,
                    activeFrames: activeFrames))
            first = end
        }
        return result
    }

    /// Longest exact-silence run after the channel has first carried signal.
    public static func longestSilentRunAfterSignal(
        _ windows: [InputChannelSignalWindow]
    ) -> Int {
        var sawSignal = false
        var current = 0
        var longest = 0
        for window in windows {
            if window.isExactlySilent {
                guard sawSignal else { continue }
                current += 1
                longest = max(longest, current)
            } else {
                sawSignal = true
                current = 0
            }
        }
        return longest
    }
}
