import Foundation
import Testing

@testable import YunAudioEngine

/// Callback size is part of the formant algorithm, not merely a buffer detail.
///
/// The shifter originally processed only complete 256-frame hops. The product
/// negotiates 64- and 128-frame callbacks too, where that loop ran zero times
/// and the enabled stage became an exact bypass. These checks exercise the
/// production chain at every supported size and assert audible quantities.
@Suite("Formant callback sizes")
struct FormantBlockSizeTests {
    private struct Metrics {
        let differenceRMS: Double
        let outputRMS: Double
        let peak: Double
    }

    @Test("every supported callback size applies the shift at a stable level")
    func everySupportedSizeProcessesSignal() throws {
        let source = vowel(seconds: 1)
        var measured: [Metrics] = []

        for blockFrames in [64, 128, 256, 512] {
            let output = try render(
                source, maximumFrames: blockFrames,
                callbackFrames: [blockFrames])
            let metrics = metrics(source: source, output: output)
            measured.append(metrics)
            #expect(
                metrics.differenceRMS > 0.1,
                "\(blockFrames) frames was effectively a bypass: delta RMS \(metrics.differenceRMS)"
            )
            #expect(
                metrics.peak < 0.7,
                "\(blockFrames) frames peaked at \(metrics.peak)")
        }

        let levels = measured.map(\.outputRMS)
        let lowest = try #require(levels.min())
        let highest = try #require(levels.max())
        #expect(
            highest / lowest < 1.01,
            "callback size changed output RMS from \(lowest) to \(highest)")
    }

    @Test("runtime callback changes preserve one continuous stream")
    func variableCallbacksMatchFixedCallbacks() throws {
        let source = vowel(seconds: 1)
        let fixed = try render(
            source, maximumFrames: 512, callbackFrames: [512])
        let variable = try render(
            source, maximumFrames: 512,
            callbackFrames: [64, 192, 128, 384, 256, 96, 416])

        var largestDifference: Float = 0
        var squaredDifference = 0.0
        for index in source.indices {
            let difference = abs(fixed[index] - variable[index])
            largestDifference = max(largestDifference, difference)
            squaredDifference += Double(difference * difference)
        }
        let differenceRMS = sqrt(squaredDifference / Double(source.count))
        #expect(
            largestDifference < 1e-6,
            "callback boundaries changed a sample by \(largestDifference)")
        #expect(
            differenceRMS < 1e-7,
            "callback boundaries changed RMS by \(differenceRMS)")
    }

    private func render(
        _ source: [Float], maximumFrames: Int, callbackFrames: [Int]
    ) throws -> [Float] {
        let chain = try #require(
            EffectChain(
                kinds: [.formant], sampleRate: 48_000,
                maximumFrames: maximumFrames))
        chain.set("shift", of: .formant, to: 40)
        var output = [Float](repeating: 0, count: source.count)
        var start = 0
        var callback = 0
        while start < source.count {
            let frames = min(
                callbackFrames[callback % callbackFrames.count],
                source.count - start)
            source.withUnsafeBufferPointer {
                chain.inputBuffer.update(
                    from: $0.baseAddress! + start, count: frames)
            }
            let rendered = chain.render(
                frames: frames, sampleTime: Float64(start))
            #expect(rendered, "render failed at \(frames) frames")
            output.withUnsafeMutableBufferPointer {
                ($0.baseAddress! + start).update(
                    from: chain.outputBuffer, count: frames)
            }
            start += frames
            callback += 1
        }
        return output
    }

    private func vowel(seconds: Int) -> [Float] {
        let sampleRate = 48_000.0
        var samples = [Float](repeating: 0, count: Int(sampleRate) * seconds)
        for harmonic in 1...80 {
            let frequency = 120.0 * Double(harmonic)
            guard frequency < sampleRate / 2 else { break }
            let formants = [700.0, 1_220.0, 2_600.0]
            let weight = formants.enumerated().reduce(0.02) { partial, item in
                let bandwidth = 110.0 + Double(item.offset) * 60
                let distance = (frequency - item.element) / bandwidth
                return partial + (1 / (1 + distance * distance)) / Double(item.offset + 1)
            }
            for index in samples.indices {
                samples[index] +=
                    Float(
                        weight
                            * sin(
                                2 * Double.pi * frequency * Double(index)
                                    / sampleRate))
            }
        }
        let normalisation = 0.5 / (samples.map(abs).max() ?? 1)
        for index in samples.indices { samples[index] *= normalisation }
        return samples
    }

    private func metrics(source: [Float], output: [Float]) -> Metrics {
        let range = 8_192..<source.count
        var squaredDifference = 0.0
        var squaredOutput = 0.0
        var peak = 0.0
        for index in range {
            let value = Double(output[index])
            let difference = value - Double(source[index])
            squaredDifference += difference * difference
            squaredOutput += value * value
            peak = max(peak, abs(value))
        }
        return Metrics(
            differenceRMS: sqrt(squaredDifference / Double(range.count)),
            outputRMS: sqrt(squaredOutput / Double(range.count)),
            peak: peak)
    }
}
