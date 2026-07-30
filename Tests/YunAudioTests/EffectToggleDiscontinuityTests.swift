import Foundation
import Testing

@testable import YunAudioEngine

/// Quantifies the audible edge made by publishing a cold effect graph.
///
/// These are known issues rather than disabled tests: the measurements still
/// run and print on every pass, while the acceptance bounds describe what a
/// graph-level transition has to achieve. A UI animation cannot change any of
/// these numbers.
@Suite("Effect toggle continuity", .serialized)
struct EffectToggleDiscontinuityTests {
    private let blockFrames = 128
    private let switchFrame = 8_192

    @Test("enabling a cold chain neither drops nor steps the waveform")
    func enablingColdChain() throws {
        let source = sine(frames: 16_384)
        let coldInput = Array(source[switchFrame...])
        let coldOutput = try render(coldInput)
        let combined =
            Array(source[(switchFrame - blockFrames)..<switchFrame])
            + Array(coldOutput.prefix(blockFrames))
        let jump = maximumStep(combined)
        let naturalStep = maximumStep(source)
        let zeroFrames = coldOutput.prefix { abs($0) < 1e-7 }.count

        var impulse = [Float](repeating: 0, count: 2_048)
        impulse[0] = 0.5
        let impulseOutput = try render(impulse)
        let latencyShift = try #require(
            impulseOutput.firstIndex { abs($0) > 0.49 })

        print(
            "cold enable: max jump \(jump), natural \(naturalStep), "
                + "zero \(zeroFrames) frames, latency shift \(latencyShift) frames")
        #expect(latencyShift == FormantShifter.windowSize)
        withKnownIssue(
            "a cold graph is published before it has output to crossfade"
        ) {
            #expect(
                jump <= naturalStep * 1.1,
                "enable jump \(jump) exceeded the signal's \(naturalStep)")
            #expect(
                zeroFrames == 0,
                "enable inserted \(zeroFrames) consecutive silent frames")
        }
    }

    @Test("disabling a delayed chain does not jump to current input")
    func disablingDelayedChain() throws {
        let source = sine(frames: 16_384)
        let processed = try render(source)
        let combined =
            Array(processed[(switchFrame - blockFrames)..<switchFrame])
            + Array(source[switchFrame..<(switchFrame + blockFrames)])
        let jump = maximumStep(combined)
        let naturalStep = maximumStep(source)

        print("disable: max jump \(jump), natural \(naturalStep)")
        withKnownIssue(
            "removing a graph jumps from its delayed output to current input"
        ) {
            #expect(
                jump <= naturalStep * 1.1,
                "disable jump \(jump) exceeded the signal's \(naturalStep)")
        }
    }

    private func sine(frames: Int) -> [Float] {
        (0..<frames).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 997 * Double($0) / 48_000
                            + 0.37))
        }
    }

    private func render(_ source: [Float]) throws -> [Float] {
        let chain = try #require(
            EffectChain(
                kinds: [.formant], sampleRate: 48_000,
                maximumFrames: blockFrames))
        var output = [Float](repeating: 0, count: source.count)
        var start = 0
        while start < source.count {
            let frames = min(blockFrames, source.count - start)
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
        }
        return output
    }

    private func maximumStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).reduce(0) {
            max($0, abs($1.1 - $1.0))
        }
    }
}
