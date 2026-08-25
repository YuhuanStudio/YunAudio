import Foundation
import Testing

@testable import YunAudioApp

/// The virtual device is one capability, not the application.
@Suite("Without the driver installed")
struct DriverOptionalTests {

    /// The judgement two places have to share.
    ///
    /// Preselecting a destination and warning that a monitor may feed back are
    /// the same question asked twice, and if they disagree the application
    /// picks exactly the device the other half warns about.
    @Test("headphones are recognised and speakers are not")
    func headphoneNamesAgree() {
        let worn = ["AirPods Pro", "USB Headset", "MacBook Pro 的耳機", "Galaxy Buds"]
        let notWorn = [
            "MacBook Pro的揚聲器", "ASUS PG32UQ", "BlackHole 16ch", "Studio Display",
        ]
        for name in worn {
            #expect(
                RouterModel.looksLikeHeadphones(named: name),
                "\(name) should read as worn")
        }
        for name in notWorn {
            #expect(
                !RouterModel.looksLikeHeadphones(named: name),
                "\(name) should not read as worn")
        }
    }

    /// The sentence the onboarding used to carry was false, and the new one has
    /// to keep naming the single capability rather than the application.
    @Test("the notice names one capability, not the whole application")
    func noticeNamesOneCapability() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/DriverOnboarding.swift",
            encoding: .utf8)
        // The claim that was wrong: routing does not need it.
        #expect(!source.contains("loc(\n                        \"Routing needs"))
        // And what is true: everything else works, and one thing is added.
        #expect(source.contains("Everything here works without it"))
        #expect(source.contains("choose YunAudio as their microphone"))
    }

    /// The name test alone called a headset a loudspeaker.
    ///
    /// "Razer Barracuda (BT)" carries none of the words, so the feedback
    /// warning fired at somebody wearing headphones — and a warning that is
    /// wrong is a warning people learn to dismiss. A Bluetooth output settles
    /// it: nobody pairs a loudspeaker they are sitting in front of.
    @Test("a Bluetooth output is worn, whatever it is called")
    func bluetoothIsWorn() {
        #expect(!RouterModel.looksLikeHeadphones(named: "Razer Barracuda (BT)"))
        #expect(
            RouterModel.looksLikeHeadphones(
                named: "Razer Barracuda (BT)", transport: .bluetooth))
        // And a wired output still has to say so.
        #expect(
            !RouterModel.looksLikeHeadphones(named: "Studio Display", transport: .usb))
    }
}
