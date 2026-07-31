import Foundation
import Testing

@testable import YunAudioApp

/// Hearing yourself in the microphone's own headphone socket.
///
/// Every studio microphone with a headphone jack — a Razer Seiren, a Yeti, a
/// Shure MV7, every audio interface ever made — presents as *one* CoreAudio
/// device carrying both the microphone's input and the socket's output. The
/// monitor picker excluded the source device outright, so the socket people buy
/// those microphones for was the one output it would not offer; and choosing it
/// as the destination is refused, correctly, with "the input and the output
/// cannot be the same device". Between the two there was no way in at all.
@Suite("monitoring on the microphone's own socket")
struct MonitorOnTheMicrophoneTests {

    private let mic = "AppleUSBAudioEngine:Razer:Seiren V3 Pro"
    private let blackHole = "BlackHole16ch_UID"

    @Test("the microphone's own output can carry the monitor")
    func theSocketIsOffered() {
        // The case that was impossible: source and monitor are one device.
        #expect(
            RouterModel.canMonitor(
                uid: mic, name: "Razer Seiren V3 Pro", hasOutput: true,
                destinationUID: blackHole))
    }

    @Test("but the destination never can, because the mix is already there")
    func theDestinationIsRefused() {
        #expect(
            !RouterModel.canMonitor(
                uid: blackHole, name: "BlackHole 16ch", hasOutput: true,
                destinationUID: blackHole))
    }

    @Test("nor our own device, which is what the far end is listening to")
    func ourOwnDeviceIsRefused() {
        #expect(
            !RouterModel.canMonitor(
                uid: "YunAudioDevice_UID", name: "YunAudio", hasOutput: true,
                destinationUID: blackHole))
    }

    @Test("and something with no output is not an output")
    func inputOnlyIsRefused() {
        #expect(
            !RouterModel.canMonitor(
                uid: mic, name: "Razer Seiren V3 Pro", hasOutput: false,
                destinationUID: blackHole))
    }
}
