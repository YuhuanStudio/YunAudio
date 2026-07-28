import Accelerate
import Foundation

/// What key a piece of music is in, worked out from the sound.
///
/// This exists for singing. Every karaoke machine ever built has a transpose
/// button, and the reason is that a song is written in the key its original
/// singer could reach: put a baritone in front of a track recorded by a
/// soprano and the chorus is simply out of range. The pitch shifter to fix that
/// is already in this application. What was missing was knowing *how far* to
/// shift, and the honest answer to that is not "guess" — it is to measure the
/// key of what is playing and the range of the person singing, and subtract.
///
/// The method is the Krumhansl-Schmuckler profile match, which is the standard
/// one and is thirty years old: fold the spectrum into twelve pitch classes,
/// then correlate that chroma against a profile of how much each degree of a
/// major and a minor scale is used. The best of the twenty-four correlations is
/// the answer.
///
/// It is not infallible and nothing that does this is. Relative major and minor
/// share every note, so C major and A minor differ only in emphasis; a key
/// change halfway through gives one answer for the whole piece. The confidence
/// is reported for exactly that reason — a weak match means "this is a guess"
/// and the interface should say so rather than printing a letter.
public struct KeyDetector: Sendable {

    public struct Key: Sendable, Hashable {
        /// 0 = C, 1 = C♯, … 11 = B.
        public let pitchClass: Int
        public let isMinor: Bool
        /// How far ahead of the runner-up, 0 to 1. Below about 0.15 the answer
        /// is not worth showing as a fact.
        public let confidence: Double

        public var name: String {
            KeyDetector.noteNames[pitchClass] + (isMinor ? "m" : "")
        }

        /// Semitones to shift to reach another key, taking the shorter way
        /// round: a singer asked to move eleven semitones up will move one
        /// down instead, and it is the same key.
        public func semitones(to other: Key) -> Int {
            let raw = (other.pitchClass - pitchClass + 12) % 12
            return raw > 6 ? raw - 12 : raw
        }
    }

    static let noteNames = [
        "C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B",
    ]

    /// Krumhansl and Kessler's key profiles, from their 1982 probe-tone
    /// experiments. These are the published numbers, not a reimplementation of
    /// them — they are the weights listeners actually assigned to each degree.
    static let majorProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
    ]
    static let minorProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
    ]

    /// Twelve numbers: how much energy sits in each pitch class.
    ///
    /// Every octave folded together, which is the point — a chroma says "there
    /// is a lot of G in this" without caring which G.
    public static func chroma(
        magnitudes: [Float], sampleRate: Double, binCount: Int
    ) -> [Double] {
        var bins = [Double](repeating: 0, count: 12)
        guard binCount > 1, sampleRate > 0 else { return bins }
        let hertzPerBin = sampleRate / Double(binCount * 2)
        for index in 1..<min(magnitudes.count, binCount) {
            let hertz = Double(index) * hertzPerBin
            // Below the bottom of a bass guitar and above where pitch stops
            // being pitch, a bin carries rumble or cymbals rather than a note.
            guard hertz >= 55, hertz <= 5000 else { continue }
            let midi = 69 + 12 * log2(hertz / 440)
            let pitchClass = Int(midi.rounded()) % 12
            guard pitchClass >= 0 else { continue }
            // Magnitude rather than power: power lets one loud bass note drown
            // out the harmony that decides the mode.
            bins[pitchClass] += Double(magnitudes[index])
        }
        return bins
    }

    /// Matches a chroma against all twenty-four keys.
    ///
    /// - Returns: Nil when there is nothing to match — silence, or a chroma
    ///   with no variation at all, which is what a sine wave or a noise floor
    ///   produces and neither is in a key.
    public static func key(from chroma: [Double]) -> Key? {
        guard chroma.count == 12 else { return nil }
        let total = chroma.reduce(0, +)
        guard total > 0 else { return nil }

        var scores: [(key: Key, score: Double)] = []
        for tonic in 0..<12 {
            for minor in [false, true] {
                let profile = minor ? minorProfile : majorProfile
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                guard let correlation = Self.correlation(chroma, rotated) else { continue }
                scores.append(
                    (Key(pitchClass: tonic, isMinor: minor, confidence: 0), correlation))
            }
        }
        guard scores.count > 1 else { return nil }
        scores.sort { $0.score > $1.score }
        let best = scores[0]
        let runnerUp = scores[1]
        // Confidence as the gap to the runner-up rather than the correlation
        // itself. A correlation of 0.9 means nothing if twelve other keys also
        // score 0.9; what matters is whether anything else came close.
        let gap = max(0, best.score - runnerUp.score)
        guard best.score > 0 else { return nil }
        return Key(
            pitchClass: best.key.pitchClass, isMinor: best.key.isMinor,
            confidence: min(1, gap / 0.2))
    }

    /// Pearson's correlation, or nil when either side does not vary.
    static func correlation(_ first: [Double], _ second: [Double]) -> Double? {
        let count = Double(first.count)
        let meanFirst = first.reduce(0, +) / count
        let meanSecond = second.reduce(0, +) / count
        var covariance = 0.0
        var varianceFirst = 0.0
        var varianceSecond = 0.0
        for index in first.indices {
            let a = first[index] - meanFirst
            let b = second[index] - meanSecond
            covariance += a * b
            varianceFirst += a * a
            varianceSecond += b * b
        }
        guard varianceFirst > 0, varianceSecond > 0 else { return nil }
        return covariance / (varianceFirst * varianceSecond).squareRoot()
    }

    // MARK: What to do about it

    /// How far to move a song so somebody can actually sing it.
    ///
    /// The rule is comfort rather than theory: a singer's range has a middle,
    /// the song has a middle, and the shift that lines those two up is the one
    /// that stops the chorus being out of reach. Both are measured — the song's
    /// from its key, the singer's from what they have actually been singing —
    /// so this is arithmetic rather than a preference.
    ///
    /// - Parameters:
    ///   - songKey: What the backing track is in.
    ///   - comfortableMidi: The middle of the singer's measured range, as a
    ///     MIDI note number.
    /// - Returns: Semitones, always within an octave: moving a song more than
    ///   six semitones makes it a different song rather than an easier one.
    public static func suggestedShift(songKey: Key, comfortableMidi: Double) -> Int {
        // The tonic nearest the singer's middle, in whichever octave that is.
        let octave = (comfortableMidi / 12).rounded()
        let tonicNearby = octave * 12 + Double(songKey.pitchClass)
        let difference = comfortableMidi - tonicNearby
        let semitones = Int(difference.rounded())
        return max(-6, min(6, semitones))
    }

    /// Semitones as the pitch stage wants them.
    public static func cents(fromSemitones semitones: Int) -> Float {
        Float(semitones) * 100
    }
}
