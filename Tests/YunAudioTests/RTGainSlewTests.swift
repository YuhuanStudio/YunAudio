import Foundation
import Testing
@testable import YunAudioEngine

@Suite("Realtime gain slew")
struct RTGainSlewTests {
    @Test("the realtime state remains four scalar words")
    func fixedLayout() {
        #expect(MemoryLayout<RTGainSlew>.stride == 16)
    }

    @Test("linear ramps finish on the exact requested frame")
    func exactLinearEndpoint() {
        var mute = RTGainSlew(1)
        mute.retargetLinear(to: 0, frames: 240)
        var penultimate: Float = 0
        for frame in 0..<240 {
            let value = mute.nextLinear()
            if frame == 238 { penultimate = value }
        }
        #expect(penultimate > 0)
        #expect(mute.current == 0)
        #expect(mute.remainingFrames == 0)

        var unmute = RTGainSlew(0)
        unmute.retargetLinear(to: 1, frames: 480)
        for _ in 0..<480 { _ = unmute.nextLinear() }
        #expect(unmute.current == 1)
        #expect(unmute.remainingFrames == 0)

        var single = RTGainSlew(-1)
        single.retargetLinear(to: 1, frames: 1)
        #expect(single.current == -1)
        #expect(single.nextLinear() == 1)

        var immediate = RTGainSlew(-1)
        immediate.retargetLinear(to: 1, frames: 0)
        #expect(immediate.current == 1)
    }

    @Test("retargeting continues from the value already heard")
    func midRampRetarget() {
        var slew = RTGainSlew(1)
        slew.retargetLinear(to: 0.2, frames: 480)
        for _ in 0..<137 { _ = slew.nextLinear() }
        let before = slew.current

        slew.retargetLinear(to: 0.8, frames: 480)
        let after = slew.nextLinear()
        let allowed = abs(0.8 - before) / 480 + 2e-7
        #expect(abs(after - before) <= allowed)
        #expect(after > before)
    }

    @Test("advancing without a buffer preserves the same timeline")
    func skippedBufferAdvances() {
        var rendered = RTGainSlew(1)
        var skipped = RTGainSlew(1)
        rendered.retargetLinear(to: 0, frames: 480)
        skipped.retargetLinear(to: 0, frames: 480)

        for _ in 0..<137 { _ = rendered.nextLinear() }
        skipped.advanceLinear(frames: 137)
        #expect(abs(rendered.current - skipped.current) < 2e-6)
        #expect(rendered.remainingFrames == skipped.remainingFrames)
    }

    @Test("a huge duration uses one consistent effective frame count")
    func hugeDurationIsClampedBeforeSlope() {
        var slew = RTGainSlew(0)
        slew.retargetLinear(to: 1, frames: Int(Int32.max) + 1)
        #expect(slew.remainingFrames == Int32.max)
        let impliedChange =
            Double(slew.linearStep) * Double(slew.remainingFrames)
        #expect(abs(impliedChange - 1) < 1e-6)
    }

    @Test("opposite finite extremes keep every linear value finite")
    func linearExtremesStayFinite() {
        let magnitude = Float.greatestFiniteMagnitude
        var slew = RTGainSlew(-magnitude)
        slew.retargetLinear(to: magnitude, frames: 3)
        #expect(slew.linearStep.isFinite)
        for _ in 0..<3 {
            let value = slew.nextLinear()
            #expect(value.isFinite)
            #expect(value >= -magnitude)
            #expect(value <= magnitude)
        }
        #expect(slew.current == magnitude)

        var skipped = RTGainSlew(-magnitude)
        skipped.retargetLinear(to: magnitude, frames: 3)
        skipped.advanceLinear(frames: 2)
        #expect(skipped.current.isFinite)
        #expect(skipped.current > -magnitude)
        #expect(skipped.current < magnitude)
    }

    @Test("one pole ducking keeps its time constants per sample")
    func onePoleTimeConstants() {
        let attack = Float(exp(-1.0 / (0.08 * 48_000)))
        var duck = RTGainSlew(1)
        for _ in 0..<3_840 {
            _ = duck.nextOnePole(towards: 0.1, coefficient: attack)
        }
        #expect(abs(duck.current - 0.4310915) < 2e-4)

        let release = Float(exp(-1.0 / (0.6 * 48_000)))
        duck = RTGainSlew(0.1)
        for _ in 0..<28_800 {
            _ = duck.nextOnePole(towards: 1, coefficient: release)
        }
        // A Float coefficient has no representable value closer to the ideal
        // 600 ms result than this tolerance; the neighbouring values miss in
        // the opposite direction by more.
        #expect(abs(duck.current - 0.6689085) < 3e-4)
    }

    @Test("one pole rejects unstable coefficients without changing state")
    func onePoleRejectsUnstableCoefficients() {
        for coefficient in [-1, 1.01, Float.greatestFiniteMagnitude, .nan] {
            var slew = RTGainSlew(0.25)
            slew.retargetLinear(to: 0.75, frames: 10)
            let before = slew
            _ = slew.nextOnePole(towards: 0.5, coefficient: coefficient)
            #expect(slew == before)
        }
    }

    @Test("one pole interpolation of finite extremes stays finite")
    func onePoleExtremesStayFinite() {
        let magnitude = Float.greatestFiniteMagnitude
        for coefficient: Float in [0, 0.5, 1] {
            var slew = RTGainSlew(-magnitude)
            let value = slew.nextOnePole(
                towards: magnitude, coefficient: coefficient)
            #expect(value.isFinite)
            #expect(value >= -magnitude)
            #expect(value <= magnitude)
            if coefficient == 0 { #expect(value == magnitude) }
            if coefficient == 1 { #expect(value == -magnitude) }
        }
    }

    @Test("callback partitioning cannot change a linear ramp")
    func blockSizeInvariant() {
        var reference = RTGainSlew(1)
        reference.retargetLinear(to: 0.25, frames: 480)
        var expected: [Float] = []
        for _ in 0..<1_024 { expected.append(reference.nextLinear()) }

        for block in [64, 128, 256, 512] {
            var candidate = RTGainSlew(1)
            candidate.retargetLinear(to: 0.25, frames: 480)
            var actual: [Float] = []
            var rendered = 0
            while rendered < 1_024 {
                let frames = min(block, 1_024 - rendered)
                for _ in 0..<frames { actual.append(candidate.nextLinear()) }
                rendered += frames
            }
            #expect(
                zip(actual, expected).allSatisfy { abs($0 - $1) < 2e-6 },
                "partition \(block)")
        }
    }
}
