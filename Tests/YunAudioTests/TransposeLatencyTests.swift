import AVFoundation
import Foundation
import Testing

@testable import YunAudioApp

/// What a time-pitch unit will tell you about the buffer it holds.
///
/// The words are held back by this number so they do not run ahead of the music
/// the moment somebody changes key — which would read as the lyric file being
/// wrong and get corrected in the wrong place. The gate reported
/// `transpose latency 0.0 ms at +2 semitones` with the song playing, so either
/// the unit holds nothing or it was being asked the wrong question.
///
/// Manual rendering, so this is a fact about the unit rather than about
/// whatever audio hardware happens to be attached.
@Suite("What the transpose says it is holding")
struct TransposeLatencyTests {

    private func runningEngine() throws -> (AVAudioEngine, AVAudioUnitTimePitch) {
        let engine = AVAudioEngine()
        let transpose = AVAudioUnitTimePitch()
        transpose.pitch = 200
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(transpose)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        engine.connect(player, to: transpose, format: format)
        engine.connect(transpose, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        return (engine, transpose)
    }

    /// Both readings, so the answer is a measurement rather than a belief.
    @Test("the node property and the unit property, measured")
    func bothReadingsAreRecorded() throws {
        let (engine, transpose) = try runningEngine()
        defer { engine.stop() }

        let node = transpose.latency
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioUnitGetProperty(
            transpose.audioUnit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
            &seconds, &size)

        print(
            String(
                format:
                    "transpose at +200 cents: AVAudioNode.latency %.6f s, "
                    + "kAudioUnitProperty_Latency %.6f s (status %d)",
                node, seconds, Int(status)))

        // Recorded rather than asserted, because the answer is that neither
        // does: both read 0.000000 s with a status of noErr, at +200 cents, in
        // a running engine. The unit will not say, so the number has to be
        // measured instead — see below.
        #expect(status == noErr)
        #expect(node == 0)
        #expect(seconds == 0)
    }

    /// So measure it: one impulse in, and find where it comes out.
    ///
    /// This is what "what it is holding" means, and it does not depend on the
    /// unit being willing to describe itself. Offline, so it is a fact about
    /// the unit rather than about the hardware.
    @Test("an impulse comes out late, and by how much")
    func impulseRevealsTheDelay() throws {
        for cents in [Float(0), 200] {
            let engine = AVAudioEngine()
            let transpose = AVAudioUnitTimePitch()
            transpose.pitch = cents
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))

            var sent = false
            let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                for buffer in list {
                    let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                    for frame in 0..<Int(frames) { samples[frame] = 0 }
                    if !sent, frames > 0 {
                        samples[0] = 1
                        sent = true
                    }
                }
                return noErr
            }
            engine.attach(source)
            engine.attach(transpose)
            engine.connect(source, to: transpose, format: format)
            engine.connect(transpose, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: 4096)
            try engine.start()
            defer { engine.stop() }

            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
            var firstAt: Int?
            var rendered = 0
            while rendered < 200_000, firstAt == nil {
                let status = try engine.renderOffline(4096, to: buffer)
                guard status == .success else { break }
                let count = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for frame in 0..<count where abs(data[frame]) > 1e-6 {
                        firstAt = rendered + frame
                        break
                    }
                }
                rendered += count
            }
            let frames = firstAt ?? -1
            print(
                "transpose at \(Int(cents)) cents: impulse emerged at frame \(frames)"
                    + (frames >= 0
                        ? String(format: " (%.1f ms)", Double(frames) / 48.0) : ""))
            #expect(frames >= 0, "the impulse never came out at \(Int(cents)) cents")
        }
    }
}
