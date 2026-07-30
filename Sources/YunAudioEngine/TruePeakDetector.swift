/// A fixed-storage, four-times oversampled true-peak detector.
///
/// The polyphase FIR is the 48-order detector specified by ITU-R BS.1770-5,
/// Annex 2. One sample advances all four phases; no storage is allocated after
/// initialisation.
struct TruePeakDetector {
    private var history = SIMD16<Float>(repeating: 0)

    /// Advances the detector and returns the greatest interpolated magnitude.
    ///
    /// Passing `false` still preserves history. Bypassing the final limiter
    /// must not leave a cold FIR whose first decision ignores the preceding
    /// eleven samples when limiting resumes.
    @inline(__always)
    mutating func push(_ sample: Float, measuring: Bool = true) -> Float {
        history[11] = history[10]
        history[10] = history[9]
        history[9] = history[8]
        history[8] = history[7]
        history[7] = history[6]
        history[6] = history[5]
        history[5] = history[4]
        history[4] = history[3]
        history[3] = history[2]
        history[2] = history[1]
        history[1] = history[0]
        history[0] = sample

        guard measuring else { return 0 }

        var phases = SIMD4<Float>(repeating: history[0]) * Self.coefficient0
        phases += SIMD4<Float>(repeating: history[1]) * Self.coefficient1
        phases += SIMD4<Float>(repeating: history[2]) * Self.coefficient2
        phases += SIMD4<Float>(repeating: history[3]) * Self.coefficient3
        phases += SIMD4<Float>(repeating: history[4]) * Self.coefficient4
        phases += SIMD4<Float>(repeating: history[5]) * Self.coefficient5
        phases += SIMD4<Float>(repeating: history[6]) * Self.coefficient6
        phases += SIMD4<Float>(repeating: history[7]) * Self.coefficient7
        phases += SIMD4<Float>(repeating: history[8]) * Self.coefficient8
        phases += SIMD4<Float>(repeating: history[9]) * Self.coefficient9
        phases += SIMD4<Float>(repeating: history[10]) * Self.coefficient10
        phases += SIMD4<Float>(repeating: history[11]) * Self.coefficient11

        return max(abs(phases.x), abs(phases.y), abs(phases.z), abs(phases.w))
    }

    mutating func reset() {
        history = SIMD16<Float>(repeating: 0)
    }

    // Computed vectors become immediate constants in the optimised render
    // path. A lazily initialised Array here would make the first IO cycle own
    // both allocation and one-time initialisation.
    @inline(__always)
    private static var coefficient0: SIMD4<Float> {
        [0.0017089843750, -0.0291748046875, -0.0189208984375, -0.0083007812500]
    }

    @inline(__always)
    private static var coefficient1: SIMD4<Float> {
        [0.0109863281250, 0.0292968750000, 0.0330810546875, 0.0148925781250]
    }

    @inline(__always)
    private static var coefficient2: SIMD4<Float> {
        [-0.0196533203125, -0.0517578125000, -0.0582275390625, -0.0266113281250]
    }

    @inline(__always)
    private static var coefficient3: SIMD4<Float> {
        [0.0332031250000, 0.0891113281250, 0.1015625000000, 0.0476074218750]
    }

    @inline(__always)
    private static var coefficient4: SIMD4<Float> {
        [-0.0594482421875, -0.1665039062500, -0.2003173828125, -0.1022949218750]
    }

    @inline(__always)
    private static var coefficient5: SIMD4<Float> {
        [0.1373291015625, 0.4650878906250, 0.7797851562500, 0.9721679687500]
    }

    @inline(__always)
    private static var coefficient6: SIMD4<Float> {
        [0.9721679687500, 0.7797851562500, 0.4650878906250, 0.1373291015625]
    }

    @inline(__always)
    private static var coefficient7: SIMD4<Float> {
        [-0.1022949218750, -0.2003173828125, -0.1665039062500, -0.0594482421875]
    }

    @inline(__always)
    private static var coefficient8: SIMD4<Float> {
        [0.0476074218750, 0.1015625000000, 0.0891113281250, 0.0332031250000]
    }

    @inline(__always)
    private static var coefficient9: SIMD4<Float> {
        [-0.0266113281250, -0.0582275390625, -0.0517578125000, -0.0196533203125]
    }

    @inline(__always)
    private static var coefficient10: SIMD4<Float> {
        [0.0148925781250, 0.0330810546875, 0.0292968750000, 0.0109863281250]
    }

    @inline(__always)
    private static var coefficient11: SIMD4<Float> {
        [-0.0083007812500, -0.0189208984375, -0.0291748046875, 0.0017089843750]
    }
}
