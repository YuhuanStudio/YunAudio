import Foundation
import Testing

@testable import YunAudioEngine

/// Quantifies the handover at the boundary where an effect graph is published.
///
/// The chain render remains deliberately cold on enable. The transition has to
/// hide that real 1024-frame hole and the latency change; replacing the chain
/// with a warmed fixture would let this test pass for the wrong reason.
@Suite("Effect toggle continuity", .serialized)
struct EffectToggleDiscontinuityTests {
    private let blockFrames = 128
    private let switchFrame = 8_192

    @Test("enabling a cold chain neither drops nor steps the waveform")
    func enablingColdChain() throws {
        let source = sine(frames: 16_384)
        let coldInput = Array(source[switchFrame...])
        let coldOutput = try render(coldInput)
        let transitioned = transition(
            old: coldInput, new: coldOutput,
            oldLatency: 0, newLatency: FormantShifter.windowSize)
        let combined =
            Array(source[(switchFrame - blockFrames)..<switchFrame])
            + transitioned
        let jump = maximumStep(combined)
        let naturalStep = maximumStep(source)
        let zeroFrames = transitioned.prefix { abs($0) < 1e-7 }.count

        var impulse = [Float](repeating: 0, count: 2_048)
        impulse[0] = 0.5
        let impulseOutput = try render(impulse)
        let latencyShift = try #require(
            impulseOutput.firstIndex { abs($0) > 0.49 })

        print(
            "cold enable: max jump \(jump), natural \(naturalStep), "
                + "zero \(zeroFrames) frames, latency shift \(latencyShift) frames")
        #expect(latencyShift == FormantShifter.windowSize)
        #expect(
            jump <= naturalStep * 1.1,
            "enable jump \(jump) exceeded the signal's \(naturalStep)")
        #expect(
            zeroFrames == 0,
            "enable inserted \(zeroFrames) consecutive silent frames")
    }

    @Test("disabling a delayed chain does not jump to current input")
    func disablingDelayedChain() throws {
        let source = sine(frames: 16_384)
        let processed = try render(source)
        let transitioned = transition(
            old: Array(processed[switchFrame...]),
            new: Array(source[switchFrame...]),
            oldLatency: FormantShifter.windowSize, newLatency: 0)
        let combined =
            Array(processed[(switchFrame - blockFrames)..<switchFrame])
            + transitioned
        let jump = maximumStep(combined)
        let naturalStep = maximumStep(source)

        print("disable: max jump \(jump), natural \(naturalStep)")
        #expect(
            jump <= naturalStep * 1.1,
            "disable jump \(jump) exceeded the signal's \(naturalStep)")
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

    private func transition(
        old: [Float], new: [Float],
        oldLatency: Int, newLatency: Int
    ) -> [Float] {
        let controller = EffectTransition(
            sampleRate: 48_000, oldLatencyFrames: oldLatency,
            newLatencyFrames: newLatency)
        var output = [Float](repeating: 0, count: min(old.count, new.count))
        let count = output.count
        old.withUnsafeBufferPointer { oldBuffer in
            new.withUnsafeBufferPointer { newBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    var start = 0
                    while start < count {
                        let frames = min(blockFrames, count - start)
                        controller.process(
                            old: oldBuffer.baseAddress! + start,
                            new: newBuffer.baseAddress! + start,
                            output: outputBuffer.baseAddress! + start,
                            frames: frames)
                        start += frames
                    }
                }
            }
        }
        return output
    }

    private func maximumStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).reduce(0) {
            max($0, abs($1.1 - $1.0))
        }
    }
}
