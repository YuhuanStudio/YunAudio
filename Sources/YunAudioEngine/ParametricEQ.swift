import Foundation

/// A parametric equaliser curve, and the arithmetic to run it.
///
/// This exists for headphone correction, and the shape of the problem decided
/// the shape of the code. Five separate products converged on shipping AutoEq's
/// measurements — every headphone has a frequency response that is wrong in a
/// way somebody has already measured, and the correction is a list of ten or so
/// filters.
///
/// **Documents, not a database.** The file parsed here is AutoEq's own
/// `ParametricEQ.txt` export, which is what people already download for their
/// model. Bundling thousands of them would be a licensing problem, an update
/// problem, and worse for the user than dropping in the file for their exact
/// unit — the same argument that made device profiles JSON rather than code.
///
/// **Biquads, not an audio unit.** A parametric EQ is a cascade of second-order
/// sections and nothing more. Hosting an `AUNBandEQ` on the output would mean a
/// render call, an allocation risk inside somebody else's code, and a component
/// that has to be instantiated before it can say what it supports. Ten biquads
/// over a stereo buffer is a few hundred multiply-adds, allocates nothing, adds
/// no latency and cannot fail. Where a stage genuinely needs a model — voice
/// isolation — this project hosts one. This is not that.
public struct ParametricEQ: Sendable, Hashable, Codable {

    public struct Filter: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Codable {
            case peaking, lowShelf, highShelf
        }
        public var kind: Kind
        public var hertz: Float
        public var decibels: Float
        public var q: Float

        public init(kind: Kind, hertz: Float, decibels: Float, q: Float) {
            self.kind = kind
            self.hertz = hertz
            self.decibels = decibels
            self.q = q
        }
    }

    /// What the name of the headphone is, when it came from a file.
    public var name: String
    /// Applied ahead of everything else.
    ///
    /// A correction that boosts anywhere needs headroom, and AutoEq works this
    /// out for the whole curve: without it a bass lift clips before it is
    /// heard. Its own exports carry a negative preamp for exactly this reason,
    /// so ignoring the line would be worse than not correcting at all.
    public var preampDecibels: Float
    public var filters: [Filter]

    public init(name: String, preampDecibels: Float = 0, filters: [Filter]) {
        self.name = name
        self.preampDecibels = preampDecibels
        self.filters = filters
    }

    /// The most sections the realtime path will run.
    ///
    /// AutoEq's own exports are five or ten; this is generous. It is a fixed
    /// number because the coefficient block is allocated once and handed to the
    /// IO thread, and a curve that could grow without bound would mean
    /// allocating there.
    public static let maximumFilters = 24

    // MARK: Reading AutoEq's own export

    /// Parses AutoEq's `ParametricEQ.txt`.
    ///
    /// The format, by example:
    ///
    ///     Preamp: -6.8 dB
    ///     Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.70
    ///     Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
    ///
    /// Read by looking for the labels rather than by counting fields, because
    /// the exports are not all identical — some carry `LS` where others carry
    /// `LSC`, and a filter that is `OFF` still occupies a line.
    ///
    /// - Returns: Nil when nothing in the text looked like a filter, which is
    ///   the honest answer for a file somebody picked by mistake.
    public static func parse(_ text: String, name: String) -> ParametricEQ? {
        var preamp: Float = 0
        var filters: [Filter] = []

        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = fields.first else { continue }

            if first.lowercased().hasPrefix("preamp"), fields.count > 1,
                let value = Float(fields[1])
            {
                preamp = value
                continue
            }

            guard first.lowercased().hasPrefix("filter") else { continue }
            // A disabled filter is still written out, and applying one would be
            // applying a correction the file says not to.
            guard fields.contains("ON") else { continue }

            let kind: Filter.Kind
            if fields.contains("PK") || fields.contains("PEQ") {
                kind = .peaking
            } else if fields.contains("LSC") || fields.contains("LS") {
                kind = .lowShelf
            } else if fields.contains("HSC") || fields.contains("HS") {
                kind = .highShelf
            } else {
                continue
            }

            func value(after label: String) -> Float? {
                guard let index = fields.firstIndex(of: label), index + 1 < fields.count
                else { return nil }
                return Float(fields[index + 1])
            }

            guard let hertz = value(after: "Fc"), let gain = value(after: "Gain"),
                let q = value(after: "Q"), hertz > 0, q > 0
            else { continue }

            filters.append(Filter(kind: kind, hertz: hertz, decibels: gain, q: q))
            if filters.count == maximumFilters { break }
        }

        guard !filters.isEmpty else { return nil }
        return ParametricEQ(name: name, preampDecibels: preamp, filters: filters)
    }

    // MARK: Coefficients

    /// Five numbers per section — b0, b1, b2, a1, a2 — normalised by a0.
    ///
    /// The Audio EQ Cookbook forms, which is worth saying because there are
    /// several conventions for shelves and picking a different one silently
    /// changes the corner frequency by half an octave.
    public func coefficients(sampleRate: Double) -> [Float] {
        var packed: [Float] = []
        packed.reserveCapacity(filters.count * 5)
        for filter in filters {
            packed += Self.section(filter, sampleRate: sampleRate)
        }
        return packed
    }

    static func section(_ filter: Filter, sampleRate: Double) -> [Float] {
        let rate = Float(sampleRate)
        // Above Nyquist a filter has nowhere to sit, and the arithmetic below
        // returns something that is not a filter rather than failing. A
        // pass-through is the honest substitute.
        guard filter.hertz > 0, filter.hertz < rate / 2, filter.q > 0 else {
            return [1, 0, 0, 0, 0]
        }

        let amplitude = pow(10, filter.decibels / 40)
        let omega = 2 * Float.pi * filter.hertz / rate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * filter.q)
        let root = amplitude.squareRoot()

        var b0: Float
        var b1: Float
        var b2: Float
        var a0: Float
        var a1: Float
        var a2: Float

        switch filter.kind {
        case .peaking:
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosine
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosine
            a2 = 1 - alpha / amplitude
        case .lowShelf:
            let plus = amplitude + 1
            let minus = amplitude - 1
            b0 = amplitude * (plus - minus * cosine + 2 * root * alpha)
            b1 = 2 * amplitude * (minus - plus * cosine)
            b2 = amplitude * (plus - minus * cosine - 2 * root * alpha)
            a0 = plus + minus * cosine + 2 * root * alpha
            a1 = -2 * (minus + plus * cosine)
            a2 = plus + minus * cosine - 2 * root * alpha
        case .highShelf:
            let plus = amplitude + 1
            let minus = amplitude - 1
            b0 = amplitude * (plus + minus * cosine + 2 * root * alpha)
            b1 = -2 * amplitude * (minus + plus * cosine)
            b2 = amplitude * (plus + minus * cosine - 2 * root * alpha)
            a0 = plus - minus * cosine + 2 * root * alpha
            a1 = 2 * (minus - plus * cosine)
            a2 = plus - minus * cosine - 2 * root * alpha
        }

        guard a0 != 0 else { return [1, 0, 0, 0, 0] }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    // MARK: What it does to the signal

    /// The whole curve's gain at one frequency, in decibels, preamp included.
    ///
    /// Computed from the coefficients rather than from the filter definitions,
    /// so it answers for what will actually be run. Drawing the curve from the
    /// definitions instead would produce a picture that stayed right while the
    /// arithmetic underneath it was wrong — which is exactly the class of
    /// defect this project keeps finding.
    public func response(atHertz hertz: Float, sampleRate: Double) -> Float {
        var magnitude: Float = 1
        let packed = coefficients(sampleRate: sampleRate)
        let omega = 2 * Float.pi * hertz / Float(sampleRate)
        for index in stride(from: 0, to: packed.count, by: 5) {
            let b0 = packed[index]
            let b1 = packed[index + 1]
            let b2 = packed[index + 2]
            let a1 = packed[index + 3]
            let a2 = packed[index + 4]
            // H(e^jw), evaluated as a complex ratio.
            let numeratorReal = b0 + b1 * cos(omega) + b2 * cos(2 * omega)
            let numeratorImaginary = -(b1 * sin(omega) + b2 * sin(2 * omega))
            let denominatorReal = 1 + a1 * cos(omega) + a2 * cos(2 * omega)
            let denominatorImaginary = -(a1 * sin(omega) + a2 * sin(2 * omega))
            let numerator =
                (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary)
                .squareRoot()
            let denominator =
                (denominatorReal * denominatorReal
                + denominatorImaginary * denominatorImaginary).squareRoot()
            guard denominator > 0 else { continue }
            magnitude *= numerator / denominator
        }
        return preampDecibels + 20 * log10(max(magnitude, 1e-9))
    }

    /// The most any part of the curve boosts, which is what decides whether
    /// there is headroom for it.
    public func peakBoostDecibels(sampleRate: Double) -> Float {
        // Log-spaced, because a linear sweep spends most of its points above
        // 10 kHz where corrections are small and none below 100 where they are
        // largest.
        (0..<96).map { step in
            let fraction = Float(step) / 95
            let hertz = 20 * pow(1000, fraction)  // 20 Hz to 20 kHz
            return response(atHertz: hertz, sampleRate: sampleRate)
        }.max() ?? 0
    }
}
