/// The two different delays introduced by processing in the routing path.
///
/// Source processing happens before routes meet, so paths that skipped it must
/// be held back by exactly that much. Output processing happens after the mix,
/// to every path equally, so it belongs in the total somebody sees and never in
/// the alignment delay. Treating the sum as both answers makes a final output
/// stage delay the bypass path twice.
public struct ProcessingLatency: Sendable, Hashable {
    /// Delay before route summing, in frames.
    public let sourceFrames: Int
    /// Delay applied to the complete output mix, in frames.
    public let outputFrames: Int

    public init(sourceFrames: Int, outputFrames: Int) {
        self.sourceFrames = max(sourceFrames, 0)
        self.outputFrames = max(outputFrames, 0)
    }

    /// Chooses the one source-processing path that was successfully built.
    ///
    /// A multi-stage chain and the dedicated isolation unit are mutually
    /// exclusive. Keeping the choice here gives initial start and live update
    /// the same answer; the two paths previously disagreed specifically for
    /// isolation on its own.
    static func sourceStageFrames(
        chainFrames: Int?, isolationFrames: Int?
    ) -> Int {
        max(chainFrames ?? isolationFrames ?? 0, 0)
    }

    /// What paths that skipped source processing must be held back by.
    public var alignmentFrames: Int { sourceFrames }

    /// What the complete DSP path adds before the device's own latency.
    public var totalFrames: Int {
        let (sum, overflow) = sourceFrames.addingReportingOverflow(outputFrames)
        return overflow ? Int.max : sum
    }

    /// Total processing latency at a particular graph rate.
    public func totalMilliseconds(sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate * 1000
    }
}
