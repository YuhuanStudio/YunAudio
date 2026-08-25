import Foundation
import Testing

@testable import YunAudioEngine

/// Removing a copy is only an optimisation if the samples stay the same.
///
/// The reference below spells out the old formant-only route:
/// input staging → native staging → processing → output staging. The production
/// chain now processes its output staging directly, so the middle-to-output
/// copy disappears without changing the native processor or its history.
@Suite("Formant copy fast path", .serialized)
struct FormantCopyFastPathTests {
    private final class FormantHandle: @unchecked Sendable {
        let shifter: FormantShifter

        init(_ shifter: FormantShifter) {
            self.shifter = shifter
        }
    }

    private static let rates = [44_100.0, 48_000.0, 96_000.0]

    @Test("one hundred thousand live ratio writes cannot tear a render hop")
    func ratioPublicationIsAtomic() throws {
        let handle = FormantHandle(
            try #require(FormantShifter(sampleRate: 48_000)))
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "yunaudio.test.formant-control").async {
            started.wait()
            for turn in 0..<100_000 {
                handle.shifter.ratio = turn.isMultiple(of: 2) ? 0.6 : 1.6
            }
            handle.shifter.ratio = 1.25
            finished.signal()
        }

        let frames = handle.shifter.configuration.hop
        var block = [Float](repeating: 0, count: frames)
        var finiteSamples = 0
        started.signal()
        for turn in 0..<1_000 {
            for frame in 0..<frames {
                block[frame] = Float(sin(Double(turn * frames + frame) * 0.071)) * 0.2
            }
            block.withUnsafeMutableBufferPointer {
                handle.shifter.process($0.baseAddress!, count: frames)
            }
            finiteSamples += block.reduce(into: 0) { count, sample in
                if sample.isFinite { count += 1 }
            }
        }

        #expect(finished.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(finiteSamples == frames * 1_000)
        #expect(handle.shifter.ratio == 1.25)
    }

    @Test("formant-only output is bit-identical with half the staging traffic")
    func nativeOnly() throws {
        for rate in Self.rates {
            let source = signal(count: Int(rate / 4), sampleRate: rate)
            for callbackFrames in [64, 128, 256, 512] {
                let legacy = try legacyNativeOnly(
                    source, sampleRate: rate, callbackFrames: callbackFrames)
                let fast = try chain(
                    kinds: [.formant], source: source, sampleRate: rate,
                    callbackFrames: callbackFrames)

                let largestDifference = maximumDifference(legacy, fast.samples)
                let legacyBytes = source.count * MemoryLayout<Float>.size * 2
                let fastBytes = source.count * MemoryLayout<Float>.size
                print(
                    "formant copy \(Int(rate)) Hz / \(callbackFrames): "
                        + "\(legacyBytes) -> \(fastBytes) bytes, "
                        + "max error \(largestDifference)")

                #expect(!fast.hasNativeWorkBuffer)
                #expect(fastBytes * 2 == legacyBytes)
                #expect(largestDifference == 0)
            }
        }
    }

    @Test("a hosted head renders directly into the native tail")
    func hostedHead() throws {
        let rate = 48_000.0
        let callbackFrames = 512
        let source = signal(count: Int(rate / 4), sampleRate: rate)
        let combined = try chain(
            kinds: [.equaliser, .formant], source: source, sampleRate: rate,
            callbackFrames: callbackFrames)

        let head = try #require(
            EffectChain(
                kinds: [.equaliser], sampleRate: rate,
                maximumFrames: callbackFrames))
        let formant = try #require(FormantShifter(sampleRate: rate))
        formant.ratio = 1.25
        var reference = [Float](repeating: 0, count: source.count)
        var offset = 0
        while offset < source.count {
            let frames = min(callbackFrames, source.count - offset)
            source.withUnsafeBufferPointer {
                head.inputBuffer.update(from: $0.baseAddress! + offset, count: frames)
            }
            #expect(head.render(frames: frames, sampleTime: Float64(offset)))
            var block = [Float](repeating: 0, count: frames)
            block.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: head.outputBuffer, count: frames)
                formant.process($0.baseAddress!, count: frames)
            }
            reference.withUnsafeMutableBufferPointer {
                ($0.baseAddress! + offset).update(from: block, count: frames)
            }
            offset += frames
        }

        let largestDifference = maximumDifference(reference, combined.samples)
        print("formant hosted head: max error \(largestDifference), 0 tail-copy bytes")
        #expect(!combined.hasNativeWorkBuffer)
        #expect(largestDifference < 1e-6)
    }

    @Test("a hosted tail retains the intermediate native buffer")
    func hostedTail() throws {
        let rate = 48_000.0
        let callbackFrames = 512
        let source = signal(count: Int(rate / 4), sampleRate: rate)
        let combined = try chain(
            kinds: [.formant, .limiter], source: source, sampleRate: rate,
            callbackFrames: callbackFrames)

        let formant = try #require(FormantShifter(sampleRate: rate))
        formant.ratio = 1.25
        let tail = try #require(
            EffectChain(
                kinds: [.limiter], sampleRate: rate,
                maximumFrames: callbackFrames))
        var reference = [Float](repeating: 0, count: source.count)
        var offset = 0
        while offset < source.count {
            let frames = min(callbackFrames, source.count - offset)
            var block = [Float](repeating: 0, count: frames)
            source.withUnsafeBufferPointer { sourceBuffer in
                block.withUnsafeMutableBufferPointer { blockBuffer in
                    blockBuffer.baseAddress!.update(
                        from: sourceBuffer.baseAddress! + offset, count: frames)
                    formant.process(blockBuffer.baseAddress!, count: frames)
                    tail.inputBuffer.update(from: blockBuffer.baseAddress!, count: frames)
                }
            }
            #expect(tail.render(frames: frames, sampleTime: Float64(offset)))
            reference.withUnsafeMutableBufferPointer {
                ($0.baseAddress! + offset).update(from: tail.outputBuffer, count: frames)
            }
            offset += frames
        }

        let largestDifference = maximumDifference(reference, combined.samples)
        print("formant hosted tail: max error \(largestDifference), work buffer retained")
        #expect(combined.hasNativeWorkBuffer)
        #expect(largestDifference < 1e-6)
    }

    private struct ChainResult {
        let samples: [Float]
        let hasNativeWorkBuffer: Bool
    }

    private func chain(
        kinds: [EffectKind], source: [Float], sampleRate: Double,
        callbackFrames: Int
    ) throws -> ChainResult {
        let chain = try #require(
            EffectChain(
                kinds: kinds, sampleRate: sampleRate,
                maximumFrames: callbackFrames))
        chain.set("shift", of: .formant, to: 25)
        var output = [Float](repeating: 0, count: source.count)
        var offset = 0
        while offset < source.count {
            let frames = min(callbackFrames, source.count - offset)
            source.withUnsafeBufferPointer {
                chain.inputBuffer.update(from: $0.baseAddress! + offset, count: frames)
            }
            #expect(chain.render(frames: frames, sampleTime: Float64(offset)))
            output.withUnsafeMutableBufferPointer {
                ($0.baseAddress! + offset).update(
                    from: chain.outputBuffer, count: frames)
            }
            offset += frames
        }
        return ChainResult(
            samples: output,
            hasNativeWorkBuffer: chain.hasNativeWorkBufferForTesting)
    }

    private func legacyNativeOnly(
        _ source: [Float], sampleRate: Double, callbackFrames: Int
    ) throws -> [Float] {
        let formant = try #require(FormantShifter(sampleRate: sampleRate))
        formant.ratio = 1.25
        var input = [Float](repeating: 0, count: callbackFrames)
        var native = [Float](repeating: 0, count: callbackFrames)
        var output = [Float](repeating: 0, count: source.count)
        var offset = 0
        while offset < source.count {
            let frames = min(callbackFrames, source.count - offset)
            source.withUnsafeBufferPointer { sourceBuffer in
                input.withUnsafeMutableBufferPointer { inputBuffer in
                    inputBuffer.baseAddress!.update(
                        from: sourceBuffer.baseAddress! + offset, count: frames)
                }
            }
            native.withUnsafeMutableBufferPointer { nativeBuffer in
                input.withUnsafeBufferPointer {
                    nativeBuffer.baseAddress!.update(
                        from: $0.baseAddress!, count: frames)
                }
                formant.process(nativeBuffer.baseAddress!, count: frames)
                output.withUnsafeMutableBufferPointer {
                    ($0.baseAddress! + offset).update(
                        from: nativeBuffer.baseAddress!, count: frames)
                }
            }
            offset += frames
        }
        return output
    }

    private func signal(count: Int, sampleRate: Double) -> [Float] {
        (0..<count).map { index in
            let time = Double(index) / sampleRate
            return Float(
                0.24 * sin(2 * Double.pi * 173 * time + 0.31)
                    + 0.11 * sin(2 * Double.pi * 997 * time + 0.73))
        }
    }

    private func maximumDifference(_ left: [Float], _ right: [Float]) -> Float {
        zip(left, right).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
}
