import AVFoundation
import Testing

@testable import YunAudioApp

/// Taking the lead vocal out of a stereo mix, as far as that can honestly be done.
@Suite("Centre cancellation")
struct CentreCancelTests {

    private func run(
        left: [Float], right: [Float], amount: Float = 1
    ) -> (left: [Float], right: [Float]) {
        var l = left
        var r = right
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                CentreCancel.apply(
                    left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count,
                    amount: amount)
            }
        }
        return (l, r)
    }

    @Test("a voice mixed dead centre is what goes")
    func centredSignalCancels() {
        // The whole method in one assertion: a lead vocal is almost always the
        // part of the signal that is identical in both channels.
        let out = run(left: [0.5, -0.25, 1], right: [0.5, -0.25, 1])
        #expect(out.left.allSatisfy { abs($0) < 1e-6 })
        #expect(out.right.allSatisfy { abs($0) < 1e-6 })
    }

    @Test("what is only in one channel survives untouched")
    func sidesAreKept() {
        // A guitar panned hard left is not centred and has no business going
        // with the voice.
        let out = run(left: [1, 0.5], right: [0, 0])
        #expect(abs(out.left[0] - 0.5) < 1e-6)
        #expect(abs(out.right[0] + 0.5) < 1e-6)
        // The difference between the channels is preserved exactly, which is
        // the definition of keeping the sides.
        #expect(abs((out.left[0] - out.right[0]) - 1) < 1e-6)
    }

    @Test("the amount is a dial, not a switch")
    func partialCancellationLeavesSome() {
        // At 1 the bass goes with the voice and the track hollows out, so the
        // useful setting is rarely all of it.
        let half = run(left: [1], right: [1], amount: 0.5)
        #expect(abs(half.left[0] - 0.5) < 1e-6)
        let none = run(left: [1], right: [1], amount: 0)
        #expect(none.left == [1])
        // Out of range is clamped rather than inverted: a negative amount would
        // *add* the centre back at twice the level and clip.
        let over = run(left: [1], right: [1], amount: 4)
        #expect(abs(over.left[0]) < 1e-6)
        let under = run(left: [1], right: [1], amount: -2)
        #expect(under.left == [1])
    }

    @Test("the default keeps the track standing up")
    func defaultIsNotTotal() {
        // 0.85 rather than 1: far enough down for somebody to lead over it,
        // not so far that the kick and bass go with the voice.
        #expect(CentreCancel.defaultAmount > 0.5 && CentreCancel.defaultAmount < 1)
    }

    @Test("a mono recording is refused rather than silenced")
    func monoIsRefused() {
        // There is no side channel to keep, so cancelling the centre cancels
        // the whole recording — silence, and nothing saying why.
        #expect(CentreCancel.isPossible(channels: 1) == false)
        #expect(CentreCancel.isPossible(channels: 2))
        #expect(CentreCancel.isPossible(channels: 6))
    }

    @Test("an interleaved block gets the same treatment")
    func interleavedMatches() {
        var block: [Float] = [0.5, 0.5, 1, 0]
        block.withUnsafeMutableBufferPointer {
            CentreCancel.apply(interleaved: $0.baseAddress!, frames: 2, amount: 1)
        }
        #expect(abs(block[0]) < 1e-6 && abs(block[1]) < 1e-6)
        #expect(abs(block[2] - 0.5) < 1e-6 && abs(block[3] + 0.5) < 1e-6)
    }
}
