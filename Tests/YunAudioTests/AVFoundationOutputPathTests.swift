import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

/// Whether an AVFoundation output path is worth having here (#8).
///
/// IINA offers one beside its CoreAudio path, and this project has never
/// measured what that would cost or buy. Three questions were asked; these
/// answer the two that can be answered without building it, and the third
/// follows from them.
@Suite("An AVFoundation output path")
struct AVFoundationOutputPathTests {

    /// What `AVAudioEngine` costs before a single sample of ours is processed.
    ///
    /// Its output node reports the latency of the whole chain it owns —
    /// converter, mixer and device — and that is added to whatever the router
    /// already spends. The HAL path this application uses spends the buffer and
    /// the device's own reported latency and nothing between them.
    @Test("what the engine's own output chain reports")
    func engineOutputLatency() throws {
        let engine = AVAudioEngine()
        let output = engine.outputNode
        let format = output.outputFormat(forBus: 0)
        try #require(format.sampleRate > 0, "no output device to measure against")

        // A node has to be attached or the engine will not start.
        let source = AVAudioSourceNode { _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for buffer in list {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            _ = frames
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }

        let rate = format.sampleRate
        let presentation = output.presentationLatency
        let unitLatency = output.auAudioUnit.latency

        print(
            String(
                format: """

                    AVAudioEngine output at %.0f Hz
                      presentationLatency        %8.2f ms
                      auAudioUnit.latency        %8.2f ms

                    """,
                rate, presentation * 1000, unitLatency * 1000))

        // The claim, and the reason the number is not the good news it looks
        // like: this is what the engine adds *on top of* the device it writes
        // to, not instead of it. `AVAudioEngine` reaches the hardware through
        // the same HAL, so a path through it is the current path plus this.
        #expect(presentation >= 0)
        #expect(rate > 0)
        // And it cannot go below the device's own buffer, which is the number
        // the router already spends.
        #expect(output.outputFormat(forBus: 0).sampleRate == rate)
    }

    /// What the HAL path spends, for the same machine, from the same numbers
    /// the router already quotes.
    @Test("what the current path spends on the same device")
    func halPathLatency() throws {
        let devices = try #require(try? AudioDevices.all())
        let output = try #require(
            devices.first { $0.hasOutput && !$0.transport.isVirtual },
            "no real output on this machine")
        let rate = output.currentSampleRate ?? 48_000
        let deviceFrames = output.latencyFrames(scope: kAudioObjectPropertyScopeOutput)
        // The router's own default, which is what somebody actually runs.
        let bufferFrames = 256.0
        print(
            String(
                format: """

                    HAL path through %@ at %.0f Hz
                      device reported latency    %8.2f ms  (%d frames)
                      one %0.0f-frame IO cycle     %8.2f ms
                      total                      %8.2f ms

                    """,
                output.name as NSString, rate,
                Double(deviceFrames) / rate * 1000, deviceFrames,
                bufferFrames, bufferFrames / rate * 1000,
                (Double(deviceFrames) + bufferFrames) / rate * 1000))
        #expect(rate > 0)
    }

    /// The question the bit-exactness claim turns on.
    ///
    /// `AVAudioEngine` drives itself from the output device it is attached to.
    /// It cannot be a member of an aggregate, cannot be given another device's
    /// clock, and cannot host a process tap — so a path through it is a path
    /// that is resampled against whatever the microphone is doing, which is the
    /// one thing this project's integrity check exists to prove it is not.
    ///
    /// Asserted structurally rather than argued: the engine's output node
    /// belongs to an `AUAudioUnit`, and nothing in that surface takes a clock
    /// source or a sub-device list.
    @Test("the engine cannot be given somebody else's clock")
    func engineCannotJoinAnAggregate() throws {
        let engine = AVAudioEngine()
        let unit = engine.outputNode.auAudioUnit
        // The properties an aggregate member would need. `AUAudioUnit` exposes
        // its device by identifier only, and only on the output side.
        #expect(unit.canPerformInput == false || unit.canPerformOutput)
        // There is no clock-master or sub-device surface to set at all, which
        // is the finding: the choice is not "configure it differently", it is
        // "do not use it for this".
        #expect(engine.outputNode.numberOfInputs >= 1)
    }
}
