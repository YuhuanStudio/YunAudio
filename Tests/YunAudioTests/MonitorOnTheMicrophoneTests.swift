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
                destinationUID: blackHole, sourceUID: mic))
    }

    @Test("but the destination never can, because the mix is already there")
    func theDestinationIsRefused() {
        #expect(
            !RouterModel.canMonitor(
                uid: blackHole, name: "BlackHole 16ch", hasOutput: true,
                destinationUID: blackHole, sourceUID: mic))
    }

    @Test("nor our own device, which is what the far end is listening to")
    func ourOwnDeviceIsRefused() {
        #expect(
            !RouterModel.canMonitor(
                uid: "YunAudioDevice_UID", name: "YunAudio", hasOutput: true,
                destinationUID: blackHole, sourceUID: mic))
    }

    @Test("and something with no output is not an output")
    func inputOnlyIsRefused() {
        #expect(
            !RouterModel.canMonitor(
                uid: mic, name: "Razer Seiren V3 Pro", hasOutput: false,
                destinationUID: blackHole, sourceUID: mic))
    }

    @Test("a device set as both ends is still offered, because that pair cannot start")
    func theDeadEndIsOpened() {
        // Somebody trying to hear themselves sets the microphone as the output
        // first — it is the obvious control, and the picker offers it. That
        // pair is refused at start, and hiding the device from the monitor for
        // being a destination it can never actually be locked them out of both
        // controls at once: the output will not take it, and the monitor would
        // not list it until the output had been changed back to something they
        // were not thinking about.
        #expect(
            RouterModel.canMonitor(
                uid: mic, name: "Razer Seiren V3 Pro", hasOutput: true,
                destinationUID: mic, sourceUID: mic))
    }
}
