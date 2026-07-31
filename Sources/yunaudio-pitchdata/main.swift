import Foundation
import YunAudioEngine

/// Writes training data for the learned pitch estimator.
///
/// The features come out of `PitchTracker.correlationCurve` — the same code
/// that will run in the application — rather than being reimplemented in
/// Python. Two implementations of one front end is the defect this whole
/// exercise keeps finding elsewhere; there is no reason to introduce it here,
/// and a model trained on features that differ from the ones it is served is a
/// model that works in a notebook and nowhere else.
///
/// The labels are exact by construction: a harmonic stack synthesised at
/// 261.63 Hz is 261.63 Hz. What is being taught is not "what is pitch" — the
/// curve already knows that — but *which* of several honest periodicities
/// belongs to the singer when a backing track is in the microphone at the same
/// level, which is where the peak-picking rule loses every note.

let rate = 48_000.0
let arguments = CommandLine.arguments
let count = arguments.count > 1 ? Int(arguments[1]) ?? 20_000 : 20_000
let output = arguments.count > 2 ? arguments[2] : "/tmp/pitchdata"

guard
    let tracker = PitchTracker(
        sampleRate: rate,
        lowest: PitchTracker.lowestSungHertz,
        highest: PitchTracker.highestSungHertz)
else { fatalError("no tracker") }

let lags = tracker.lagRange
let width = lags.count

/// Deterministic, so a dataset can be regenerated exactly.
struct Random {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
    mutating func inRange(_ low: Double, _ high: Double) -> Double {
        low + next() * (high - low)
    }
}

func tone(
    hertz: Double, harmonics: Int, gain: Double, into buffer: inout [Float],
    random: inout Random
) {
    // A little jitter on every partial, because a voice is not a synthesiser
    // and a model trained on exact harmonics learns the synthesiser.
    let phase = random.inRange(0, 2 * .pi)
    let inharmonicity = random.inRange(0, 0.0015)
    for index in buffer.indices {
        let t = Double(index) / rate
        var sample = 0.0
        for harmonic in 1...harmonics {
            let drift = 1 + inharmonicity * Double(harmonic - 1)
            sample +=
                sin(2 * .pi * hertz * Double(harmonic) * drift * t + phase)
                / Double(harmonic)
        }
        buffer[index] += Float(sample * gain)
    }
}

var random = Random(state: 0x5EED)
var features = Data()
var labels = Data()
var written = 0

let frameSize = PitchTracker.frameSize
while written < count {
    var frame = [Float](repeating: 0, count: frameSize)

    // The singer, anywhere a sung note lives.
    // The whole sung range the tracker searches, not a comfortable subset.
    // Trained from 80 Hz up, the head had never seen a C2 at 65.41 and answered
    // an octave out — caught by the sample-rate consistency test, which uses
    // exactly that note. A model is only defined where it was shown something.
    let f0 = exp(
        random.inRange(log(PitchTracker.lowestSungHertz * 1.02),
                       log(PitchTracker.highestSungHertz * 0.98)))
    let voiceGain = random.inRange(0.15, 0.5)
    tone(
        hertz: f0, harmonics: Int(random.inRange(4, 14)), gain: voiceGain,
        into: &frame, random: &random)

    // The room. Half the frames carry an accompaniment, at levels from
    // inaudible to louder than the singer — which is the case the rule loses.
    if random.next() < 0.75 {
        let root = exp(random.inRange(log(65), log(330)))
        let chord = [1.0, 1.26, 1.5, 2.0]
        let backingGain = voiceGain * random.inRange(0.2, 1.6)
        for interval in chord where random.next() < 0.8 {
            tone(
                hertz: root * interval, harmonics: Int(random.inRange(3, 8)),
                gain: backingGain / 3, into: &frame, random: &random)
        }
    }

    // Breath, converter noise, a fan.
    let noise = random.inRange(0, 0.06)
    if noise > 0 {
        for index in frame.indices {
            frame[index] += Float(noise * (random.next() * 2 - 1))
        }
    }

    let curve = tracker.correlationCurve(frame: frame)
    guard curve.count == width else { continue }

    curve.withUnsafeBufferPointer { features.append(Data(buffer: $0)) }
    var label = Float(f0)
    withUnsafeBytes(of: &label) { labels.append(contentsOf: $0) }
    written += 1
    if written % 2000 == 0 { FileHandle.standardError.write(Data("\(written)\n".utf8)) }
}

try features.write(to: URL(fileURLWithPath: output + "-x.f32"))
try labels.write(to: URL(fileURLWithPath: output + "-y.f32"))
let meta = """
    {"rows": \(written), "width": \(width), "minimumLag": \(lags.lowerBound), \
    "maximumLag": \(lags.upperBound), "sampleRate": \(rate)}
    """
try Data(meta.utf8).write(to: URL(fileURLWithPath: output + "-meta.json"))
print(meta)
