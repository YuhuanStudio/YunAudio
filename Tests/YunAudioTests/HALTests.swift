import CoreAudio
import Foundation
import Testing

import AppKit
import SwiftUI

@testable import YunAudioApp
@testable import YunAudioEngine
@testable import YunAudioControl
@testable import YunDesign
@testable import YunAudioHAL
@testable import YunAudioRazer

// MARK: - Four-char codes

@Suite("Four-char codes")
struct FourCharTests {
    /// CoreAudio selectors and error codes are four-char codes. Rendering them
    /// as decimal makes every log line useless, which is the whole reason this
    /// helper exists.
    @Test("printable codes render as characters")
    func printable() {
        #expect(fourCharDescription(UInt32(0x6D61_696E)) == "'main'")
        #expect(fourCharDescription(UInt32(0x636C_6B64)) == "'clkd'")
    }

    @Test("non-printable codes fall back to a signed integer")
    func nonPrintable() {
        // Status codes like -50 are not four printable characters.
        #expect(fourCharDescription(Int32(-50)) == "-50")
    }
}

// MARK: - Sample rate ranges

@Suite("Sample rate ranges")
struct SampleRateTests {
    @Test("discrete ranges come through unchanged")
    func discrete() {
        let ranges = [
            AudioValueRange(mMinimum: 44100, mMaximum: 44100),
            AudioValueRange(mMinimum: 48000, mMaximum: 48000),
        ]
        #expect(AudioDevice.expand(ranges) == [44100, 48000])
    }

    /// Some virtual drivers advertise one continuous span rather than a list.
    /// A UI cannot offer an infinite set, so the span is sampled at the standard
    /// rates inside it.
    @Test("a continuous span is sampled at standard rates")
    func continuous() {
        let rates = AudioDevice.expand([AudioValueRange(mMinimum: 44100, mMaximum: 96000)])
        #expect(rates.contains(44100))
        #expect(rates.contains(48000))
        #expect(rates.contains(96000))
        #expect(!rates.contains(192_000))
        #expect(!rates.contains(8000))
    }

    @Test("overlapping ranges do not produce duplicates")
    func overlapping() {
        let rates = AudioDevice.expand([
            AudioValueRange(mMinimum: 44100, mMaximum: 48000),
            AudioValueRange(mMinimum: 48000, mMaximum: 96000),
        ])
        #expect(rates == rates.sorted())
        #expect(Set(rates).count == rates.count)
    }

    @Test("an empty list yields nothing rather than a default")
    func empty() {
        #expect(AudioDevice.expand([]).isEmpty)
    }
}

// MARK: - Clock relationships

@Suite("Clock relationships")
struct ClockRelationshipTests {
    /// Consumer hardware often publishes no clock domain — the Seiren V3 Pro
    /// does not — so "unknown" has to mean "assume resampled", never "assume
    /// fine".
    @Test("an unknown domain is not treated as bit-exact")
    func unknownIsNotExact() {
        #expect(!ClockRelationship.unknown.isBitExact)
        #expect(!ClockRelationship.differentDomains.isBitExact)
        #expect(ClockRelationship.sameDomain.isBitExact)
    }
}

// MARK: - Transport types

@Suite("Transport types")
struct TransportTests {
    @Test("virtual endpoints are recognised as such")
    func virtualTransports() {
        #expect(AudioTransport(rawValue: kAudioDeviceTransportTypeVirtual).isVirtual)
        #expect(AudioTransport(rawValue: kAudioDeviceTransportTypeAggregate).isVirtual)
        #expect(!AudioTransport(rawValue: kAudioDeviceTransportTypeUSB).isVirtual)
        #expect(!AudioTransport(rawValue: kAudioDeviceTransportTypeBuiltIn).isVirtual)
    }

    @Test("an absent transport type is unknown, not a wrong guess")
    func absent() {
        #expect(AudioTransport(rawValue: nil) == .unknown)
    }
}

// MARK: - Razer report framing

@Suite("Razer report")
struct RazerReportTests {
    @Test("a report encodes to exactly 90 bytes")
    func size() {
        let bytes = RazerReport(commandClass: 0x00, commandID: 0x81).encoded()
        #expect(bytes.count == RazerReport.size)
    }

    /// The checksum covers bytes 2 through 87. Getting the span wrong is silent:
    /// the device simply refuses everything.
    @Test("the checksum is the XOR of bytes 2 through 87")
    func checksum() {
        var report = RazerReport(commandClass: 0x03, commandID: 0x01, arguments: [1, 2, 3])
        report.transactionID = 0x1F
        let bytes = report.encoded()

        var expected: UInt8 = 0
        for index in 2..<88 { expected ^= bytes[index] }
        #expect(bytes[88] == expected)
        #expect(bytes[89] == 0)
    }

    @Test("a report survives an encode and decode round trip")
    func roundTrip() throws {
        var original = RazerReport(
            commandClass: 0x0F, commandID: 0x02, arguments: [0xAA, 0xBB, 0xCC])
        original.transactionID = 0x3F
        original.remainingPackets = 0x0102

        let decoded = try #require(RazerReport(decoding: original.encoded()))
        #expect(decoded.commandClass == 0x0F)
        #expect(decoded.commandID == 0x02)
        #expect(decoded.transactionID == 0x3F)
        #expect(decoded.remainingPackets == 0x0102)
        #expect(decoded.arguments[0] == 0xAA)
        #expect(decoded.arguments[2] == 0xCC)
    }

    @Test("a short buffer decodes to nil rather than reading past its end")
    func shortBuffer() {
        #expect(RazerReport(decoding: [UInt8](repeating: 0, count: 40)) == nil)
    }

    @Test("arguments longer than the field are truncated, not overflowed")
    func argumentOverflow() {
        let report = RazerReport(
            commandClass: 0, commandID: 0, arguments: [UInt8](repeating: 0xFF, count: 200))
        #expect(report.arguments.count == 80)
        #expect(report.dataSize == 80)
        #expect(report.encoded().count == RazerReport.size)
    }

    @Test("device status codes decode to their meanings")
    func status() {
        var report = RazerReport()
        report.status = 0x02
        #expect(report.decodedStatus == .successful)
        report.status = 0x00
        #expect(report.decodedStatus == .new)
        report.status = 0x7F
        #expect(report.decodedStatus == nil)
    }
}

// MARK: - Sample rate restoration

/// Serialised because both tests reach for the same physical device — the first
/// one the system lists — and mutate its sample rate. Run in parallel, which is
/// Swift Testing's default, one test sets a rate while the other is asserting
/// that nothing changed, and the failure looks like a bug in the code under
/// test rather than in the suite.
@Suite("Sample rate restoration", .serialized)
struct SampleRateRestorationTests {
    /// Routing has to align sample rates, and that change persists on the
    /// hardware after the process exits. Handing back what was there before is
    /// the only thing that makes the change undoable.
    @Test("aligning reports what each device was set to beforehand")
    func reportsPreviousRates() throws {
        let devices = try AudioDevices.all().filter {
            $0.availableSampleRates.contains(48000) && $0.availableSampleRates.count > 1
        }
        try #require(!devices.isEmpty, "needs a device offering more than one rate")

        let device = devices[0]
        let original = try #require(device.currentSampleRate)
        let other = try #require(device.availableSampleRates.first { $0 != original })

        let previous = try AggregateDevice.alignSampleRate(other, across: [device])
        defer { AggregateDevice.restoreSampleRates(previous) }

        #expect(previous[device.uid] == original)

        AggregateDevice.restoreSampleRates(previous)
        // Re-read rather than trusting the write: the HAL can refuse.
        let restored = try AudioDevice(id: device.id).currentSampleRate
        #expect(restored == original)
    }

    @Test("a device that is already at the target is not recorded")
    func noChangeNoRecord() throws {
        let device = try #require(try AudioDevices.all().first)
        let current = try #require(device.currentSampleRate)
        let previous = try AggregateDevice.alignSampleRate(current, across: [device])
        #expect(previous.isEmpty)
    }
}

// MARK: - Razer lighting protocol

/// Checks the encoder against frames taken off the device itself.
///
/// These two buffers are exactly what the Seiren V3 Pro returned when Synapse
/// had set the ring to a solid red, captured by polling the same feature report
/// every three milliseconds. Encoding the same intent has to reproduce them
/// byte for byte — which is the only way to know the checksum rule is right
/// before writing to somebody's microphone.
@Suite("Razer lighting")
struct RazerLightingTests {

    /// Twelve LEDs of 0xC0 0x00 0x00, which is what the samples hold.
    private var solidRed: [(r: UInt8, g: UInt8, b: UInt8)] {
        Array(repeating: (r: 0xC0, g: 0, b: 0), count: RazerLightingCommand.ledCount)
    }

    private func captured(transaction: UInt8, checksum: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x07
        bytes[1] = 0x02  // the device's own status on read-back
        bytes[2] = transaction
        bytes[6] = 0x29  // data size, 41
        bytes[7] = 0x0F
        bytes[8] = 0x03
        bytes[13] = 0x0B  // the frame prefix's last byte
        for led in 0..<12 { bytes[14 + led * 3] = 0xC0 }
        bytes[62] = checksum
        bytes[63] = checksum
        return bytes
    }

    @Test("the encoder reproduces a captured frame byte for byte")
    func matchesCapture() {
        // Two samples with different transaction ids and therefore different
        // checksums, which is what pins the checksum to covering that byte.
        for (transaction, checksum) in [(UInt8(0x00), UInt8(0x2E)), (0x0A, 0x24)] {
            var mine = RazerLightingCommand.frame(
                solidRed, transactionID: transaction
            ).encoded()
            // Byte 1 is what the device wrote back; ours is zero on the way out.
            mine[1] = 0x02
            #expect(mine == captured(transaction: transaction, checksum: checksum))
        }
    }

    /// openrazer starts the XOR after the transaction id. This device includes
    /// it, and the two captured frames differ only in that byte — so a port
    /// that kept openrazer's rule would produce the same checksum for both and
    /// be wrong about at least one.
    @Test("the checksum covers the transaction id")
    func checksumIncludesTransaction() {
        let first = RazerLightingCommand.frame(solidRed, transactionID: 0x00).encoded()
        let second = RazerLightingCommand.frame(solidRed, transactionID: 0x0A).encoded()
        #expect(first[63] != second[63])
        #expect(first[63] == 0x2E)
        #expect(second[63] == 0x24)
    }

    @Test("brightness carries its level and zero means off")
    func brightnessFrame() {
        let frame = RazerLightingCommand.brightness(0x99, transactionID: 0x04).encoded()
        #expect(frame[6] == 0x03)  // data size
        #expect(frame[8] == 0x04)  // command id
        #expect(Array(frame[9...11]) == [0x01, 0x00, 0x99])
        // Zero is the off switch; there is no separate command for it.
        let off = RazerLightingCommand.brightness(0).encoded()
        #expect(off[11] == 0x00)
    }

    @Test("a short colour list pads with black rather than repeating")
    func shortColourList() {
        let frame = RazerLightingCommand.frame([(r: 255, g: 0, b: 0)]).encoded()
        #expect(Array(frame[14...16]) == [255, 0, 0])
        // Everything after the first LED stays dark.
        #expect(Array(frame[17...49]).allSatisfy { $0 == 0 })
    }
}

// MARK: - Device channel names

/// The Seiren V3 Pro's three input channels are three versions of the same
/// microphone, and CoreAudio will not say which is which. Getting the mapping
/// wrong hands somebody a signal that sounds nearly right, which is worse than
/// one that sounds broken.
@Suite("Device channel names")
struct DeviceChannelNameTests {
    @Test("the Seiren's three inputs are named from its own topology")
    func seirenInputs() throws {
        let channels = try #require(
            DeviceChannelNames.channels(
                modelUID: nil, name: "Razer Seiren V3 Pro",
                scope: kAudioObjectPropertyScopeInput))
        #expect(channels.count == 3)
        #expect(channels[0].isDefault)
        // Channel 2 is the one worth knowing about: the device has an expander
        // ahead of its own converter, which no host-side gate can be equivalent
        // to.
        #expect(channels[2].name == "After the expander")
        #expect(channels.filter(\.isDefault).count == 1)
    }

    @Test("an unknown device gets no invented names")
    func unknownDevice() {
        #expect(
            DeviceChannelNames.channels(
                modelUID: nil, name: "Some Other Microphone",
                scope: kAudioObjectPropertyScopeInput) == nil)
    }

    /// The names describe capture. Applying them to an output scope would label
    /// a speaker "Dry".
    @Test("output scopes are never named")
    func outputScope() {
        #expect(
            DeviceChannelNames.channels(
                modelUID: nil, name: "Razer Seiren V3 Pro",
                scope: kAudioObjectPropertyScopeOutput) == nil)
    }
}

/// The ring's geometry, which the protocol capture could not settle — it came
/// from lighting one LED at a time and looking.
@Suite("Light ring geometry")
struct LightRingGeometryTests {
    @Test("index 0 is at the bottom and index 6 at the top")
    func extremes() {
        #expect(RazerLightingCommand.height(ofLED: 0) == 0)
        #expect(abs(RazerLightingCommand.height(ofLED: 6) - 1) < 0.0001)
    }

    /// Filling by height is only a level meter if the two sides match. If they
    /// drifted the ring would fill lopsidedly, which reads as a fault.
    @Test("the two sides sit at matching heights")
    func symmetric() {
        for index in 1...5 {
            let left = RazerLightingCommand.height(ofLED: index)
            let right = RazerLightingCommand.height(ofLED: 12 - index)
            #expect(abs(left - right) < 0.0001)
        }
    }

    @Test("height rises monotonically up one side")
    func monotonic() {
        for index in 0..<6 {
            #expect(
                RazerLightingCommand.height(ofLED: index)
                    < RazerLightingCommand.height(ofLED: index + 1))
        }
    }
}

/// What the ring shows, checked directly rather than through the device.
///
/// The first version of these checks read frames back off the hardware while
/// the router was running, and the router pushes the real level twenty times a
/// second — so anything a test set was overwritten within a frame and the check
/// was measuring read latency rather than behaviour.
@Suite("Light ring rendering")
struct LightRingRenderingTests {
    private let blue: RazerRing.Colour = (0, 120, 255)

    private func litCount(_ frame: [RazerRing.Colour]) -> Int {
        frame.filter { $0 != RazerRing.dark }.count
    }

    @Test("silence leaves the ring dark")
    func silence() {
        #expect(litCount(RazerRing.level(0, colour: blue, isMuted: false)) == 0)
    }

    @Test("more of the ring lights as the level rises")
    func rises() {
        let quiet = litCount(RazerRing.level(0.05, colour: blue, isMuted: false))
        let loud = litCount(RazerRing.level(0.5, colour: blue, isMuted: false))
        let full = litCount(RazerRing.level(1, colour: blue, isMuted: false))
        #expect(quiet > 0)
        #expect(loud > quiet)
        #expect(full == RazerLightingCommand.ledCount)
    }

    /// The ring has to fill evenly up both sides. Filling by index instead of
    /// by height would light one side first, which reads as a chase rather than
    /// a level.
    @Test("the ring fills symmetrically rather than sweeping round")
    func symmetric() {
        let frame = RazerRing.level(0.3, colour: blue, isMuted: false)
        for index in 1...5 {
            #expect((frame[index] != RazerRing.dark) == (frame[12 - index] != RazerRing.dark))
        }
    }

    /// Muted and quiet must not look alike: an unlit ring is already what
    /// silence looks like, so muting is the whole ring in red.
    @Test("muting is unmistakable, whatever the level")
    func muted() {
        for level in [Float(0), 0.3, 1] {
            let frame = RazerRing.level(level, colour: blue, isMuted: true)
            #expect(frame.allSatisfy { $0 == RazerRing.muted })
        }
    }

    @Test("the top of the ring warns before it clips")
    func headroom() {
        let full = RazerRing.level(1, colour: blue, isMuted: false)
        #expect(full.contains { $0 == RazerRing.danger })
        #expect(full.contains { $0 == RazerRing.warning })
    }

    @Test("the spectrum turns rather than standing still")
    func spectrumTurns() {
        func flatten(_ frame: [RazerRing.Colour]) -> [UInt8] {
            frame.flatMap { [$0.r, $0.g, $0.b] }
        }
        #expect(flatten(RazerRing.spectrum(step: 0)) != flatten(RazerRing.spectrum(step: 30)))
        // Ninety steps is one full turn, so it comes back to itself — within a
        // unit, because the wrap goes through a floating point remainder and
        // asserting exactness would be claiming something the code never
        // promised.
        let start = flatten(RazerRing.spectrum(step: 0))
        let turned = flatten(RazerRing.spectrum(step: 90))
        #expect(zip(start, turned).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }
}

// MARK: - Device profiles

/// Knowledge about hardware is a document now rather than a compiled table, so
/// these check both that the shipped document still says what it should and
/// that a bad one cannot take the application with it.
@Suite("Device profiles")
struct DeviceProfileTests {

    /// That the file was actually read, not that the fallback happens to agree
    /// with it.
    ///
    /// Two tests here passed for a while with nothing loading at all, because
    /// what they asserted was also true of the compiled-in fallback. This one
    /// cannot be satisfied that way.
    @Test("the shipped profiles are really loaded from disk")
    func libraryIsPopulated() {
        #expect(!DeviceChannelNames.shared.library.profiles.isEmpty)
        #expect(DeviceChannelNames.shared.problems.isEmpty)
    }

    @Test("the shipped profile still names the Seiren's three inputs")
    func shippedProfileLoads() throws {
        let channels = try #require(
            DeviceChannelNames.channels(
                modelUID: nil, name: "Razer Seiren V3 Pro",
                scope: kAudioObjectPropertyScopeInput))
        #expect(channels.count == 3)
        #expect(channels[0].name == "Microphone")
        #expect(channels[2].name == "After the expander")
        #expect(channels.filter(\.isDefault).count == 1)
        #expect(channels.allSatisfy { !$0.detail.isEmpty })
    }

    /// The note is what tells somebody their microphone exposes no gain to
    /// macOS, which is the difference between a useful instruction and a
    /// useless one.
    @Test("a profile can carry a note about the device")
    func note() throws {
        let note = try #require(
            DeviceChannelNames.note(modelUID: nil, name: "Razer Seiren V3 Pro"))
        #expect(note.lowercased().contains("gain"))
    }

    @Test("an unknown device gets nothing invented for it")
    func unknownDevice() {
        #expect(
            DeviceChannelNames.channels(
                modelUID: nil, name: "Some Other Microphone",
                scope: kAudioObjectPropertyScopeInput) == nil)
    }

    /// Output scopes are never named: the profiles describe inputs.
    @Test("output scopes are not matched")
    func outputScope() {
        #expect(
            DeviceChannelNames.channels(
                modelUID: nil, name: "Razer Seiren V3 Pro",
                scope: kAudioObjectPropertyScopeOutput) == nil)
    }

    /// Longest match wins, or a general entry dropped in a folder silently
    /// takes over from every specific one already there.
    @Test("a more specific profile beats a general one")
    func specificWins() {
        let library = DeviceProfileLibrary(profiles: [
            DeviceProfile(
                match: "seiren",
                inputChannels: [DeviceProfile.Channel(name: "General", detail: "x")]),
            DeviceProfile(
                match: "seiren v3 pro",
                inputChannels: [DeviceProfile.Channel(name: "Specific", detail: "x")]),
        ])
        #expect(
            library.profile(modelUID: nil, name: "Razer Seiren V3 Pro")?
                .inputChannels.first?.name == "Specific")
        #expect(
            library.profile(modelUID: nil, name: "Razer Seiren V2 X")?
                .inputChannels.first?.name == "General")
    }

    /// These files come from outside. One that will not parse must be skipped,
    /// not fatal — a bad file in the folder cannot be allowed to stop the
    /// application knowing about the rest of them, let alone to stop it
    /// starting.
    @Test("a malformed file is skipped and named rather than fatal")
    func malformedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "this is not json".write(
            to: directory.appendingPathComponent("broken.json"), atomically: true,
            encoding: .utf8)
        try #"""
        {"match":"test mic","inputChannels":[{"name":"One","detail":"d"}]}
        """#.write(
            to: directory.appendingPathComponent("good.json"), atomically: true,
            encoding: .utf8)

        let (loaded, problems) = DeviceProfileLibrary.load(from: directory)
        if loaded.count != 1 { Issue.record("problems: \(problems)") }
        #expect(loaded.count == 1)
        #expect(loaded[0].match == "test mic")
        #expect(problems.count == 1)
        // Named, so somebody can fix theirs.
        #expect(problems[0].contains("broken.json"))
    }

    /// The whole point of the format is that somebody can write one by hand,
    /// so everything optional has to actually be optional. A Swift default
    /// value does not make a key optional to a decoder — the synthesised
    /// decoder demanded `isDefault` on every channel until this was written
    /// out.
    @Test("only the name is required of a hand-written channel")
    func minimalProfile() throws {
        let data = Data(#"{"match":"x","inputChannels":[{"name":"Only"}]}"#.utf8)
        let profile = try JSONDecoder().decode(DeviceProfile.self, from: data)
        #expect(profile.inputChannels.count == 1)
        #expect(profile.inputChannels[0].name == "Only")
        #expect(profile.inputChannels[0].detail.isEmpty)
        #expect(!profile.inputChannels[0].isDefault)
        #expect(profile.displayName == nil)
        #expect(profile.note == nil)
    }

    /// A folder that is not there at all is the normal case for somebody who
    /// has never added a profile.
    @Test("a missing folder is not a problem")
    func missingFolder() {
        let (loaded, problems) = DeviceProfileLibrary.load(
            from: URL(fileURLWithPath: "/nonexistent/yunaudio/devices"))
        #expect(loaded.isEmpty)
        #expect(problems.isEmpty)
    }

    /// The Seiren V2 X is the microphone that publishes a gain macOS can set —
    /// −15 dB to +15 dB, measured on this machine, against the V3 Pro's
    /// nothing. Somebody reading the profile has to be told which of their two
    /// Razer microphones that is.
    @Test("the V2 X profile names its one channel and says what it does publish")
    func seirenV2XProfile() throws {
        let channels = try #require(
            DeviceChannelNames.channels(
                modelUID: "Razer Seiren V2 X:1532:0543", name: "Razer Seiren V2 X",
                scope: kAudioObjectPropertyScopeInput))
        // One, not three. Matching the V3 Pro's three would be the easy mistake
        // and would label a channel that does not exist.
        #expect(channels.count == 1)
        #expect(channels[0].isDefault)
        #expect(!channels[0].detail.isEmpty)

        let note = try #require(
            DeviceChannelNames.note(
                modelUID: "Razer Seiren V2 X:1532:0543", name: "Razer Seiren V2 X"))
        #expect(note.contains("-15 dB to +15 dB"))
        // The two profiles have to disagree about this, or one of them is wrong.
        let v3 = try #require(
            DeviceChannelNames.note(modelUID: nil, name: "Razer Seiren V3 Pro"))
        #expect(note.contains("settable") && v3.contains("no settable"))
    }

    /// Two CoreAudio devices, one headset, and a 16 kHz input that looks like a
    /// fault until somebody says the capsule stops at 10 kHz.
    @Test("the Barracuda's Bluetooth profile covers both of its devices")
    func barracudaProfile() throws {
        // The headset is two CoreAudio devices, and they publish the same name
        // and the same model UID — only the `:input` and `:output` suffix on
        // the device UID differs, and the matcher never sees that. So one
        // profile covers both, which is the intent rather than an accident.
        let note = try #require(
            DeviceChannelNames.note(modelUID: "2002 7e3", name: "Razer Barracuda (BT)"))
        #expect(note.contains("16 kHz and nothing else"))
        #expect(note.contains("hands-free"))
        #expect(note.contains("2.4 GHz dongle"))

        let channels = try #require(
            DeviceChannelNames.channels(
                modelUID: "2002 7e3", name: "Razer Barracuda (BT)",
                scope: kAudioObjectPropertyScopeInput))
        #expect(channels.count == 1)
        // Why 16 kHz is not the insult it looks like.
        #expect(channels[0].detail.contains("100 Hz to 10 kHz"))
    }

    /// The headset has three identities and only the Bluetooth one was measured
    /// here. The dongle gets the general profile, which must say something
    /// different — a note that repeated the Bluetooth measurements would be
    /// stating one mode's numbers about another's.
    @Test("the dongle gets the general profile, not the Bluetooth one")
    func barracudaModesAreDistinct() throws {
        let dongle = try #require(
            DeviceChannelNames.note(modelUID: nil, name: "Razer Barracuda 2.4"))
        let bluetooth = try #require(
            DeviceChannelNames.note(modelUID: nil, name: "Razer Barracuda (BT)"))
        #expect(dongle != bluetooth)
        #expect(!dongle.contains("hands-free"))
        // Razer's own ten band centres, written out so somebody arriving from
        // Synapse can rebuild their curve here instead of guessing at it. Spelt
        // in full because a test for "30" would pass on any prose at all.
        #expect(dongle.contains("30, 60, 120, 250, 500 Hz, 1, 2, 4, 8 and 16 kHz"))
        #expect(dongle.contains("plus or minus 5 dB"))
    }

    /// A profile is matched on a substring, so a file that says too little can
    /// quietly capture a device it knows nothing about. These four names all
    /// belong to hardware this project has profiles for, and each must land on
    /// its own.
    ///
    /// This caught exactly that: what wins is the *longest* match, not the most
    /// specific one, and "razer barracuda" is a character longer than
    /// "barracuda (bt)" — so the general profile took the Bluetooth device and
    /// told its owner nothing about the 16 kHz input.
    @Test("each Razer device gets its own profile and not a neighbour's")
    func profilesDoNotPoachEachOther() throws {
        let expected: [(String, String)] = [
            ("Razer Seiren V3 Pro", "seiren v3 pro"),
            ("Razer Seiren V2 X", "seiren v2 x"),
            ("Razer Barracuda (BT)", "razer barracuda (bt)"),
            ("Razer Barracuda 2.4", "razer barracuda"),
        ]
        let library = DeviceChannelNames.shared.library
        for (name, match) in expected {
            let profile = try #require(library.profile(modelUID: nil, name: name))
            #expect(profile.match == match, "\(name) matched \(profile.match)")
        }
        // And nothing invented for the other Razer hardware in the world.
        #expect(library.profile(modelUID: nil, name: "Razer Kraken") == nil)
    }

    /// The round trip has to survive, or a profile written by the application
    /// cannot be read back by it.
    @Test("a profile survives being written and read")
    func roundTrip() throws {
        let original = DeviceProfile(
            match: "example",
            displayName: "Example",
            inputChannels: [
                DeviceProfile.Channel(name: "A", detail: "first", isDefault: true),
                DeviceProfile.Channel(name: "B", detail: "second"),
            ],
            note: "something worth knowing")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(DeviceProfile.self, from: data) == original)
    }
}

// MARK: - Application grouping

/// What the application list offers somebody, stated as data rather than as
/// whatever happened to be running.
///
/// The rules were only reachable through a live HAL before this, so the one
/// thing nobody had checked was the case that matters most: something is
/// audible and the list does not have it. On this machine the HAL reported two
/// processes playing and the grouping returned one.
@Suite("Application grouping")
struct AudioApplicationGroupingTests {

    private func process(
        _ id: AudioObjectID, pid: pid_t, bundle: String?, name: String, playing: Bool = false
    ) -> AudioApplications.ProcessEntry {
        AudioApplications.ProcessEntry(
            id: id, pid: pid, bundleID: bundle, name: name, isPlaying: playing)
    }

    /// Discord is four processes and one row.
    @Test("helpers fold into the application that spawned them")
    func helpersFold() {
        let apps = AudioApplications.group(
            processes: [
                process(1, pid: 10, bundle: "com.hnc.Discord", name: "Discord"),
                process(2, pid: 11, bundle: "com.hnc.Discord.helper", name: "Helper"),
                process(
                    3, pid: 12, bundle: "com.hnc.Discord.helper.Renderer", name: "Renderer"),
                process(4, pid: 13, bundle: "com.hnc.Discord.helper.Plugin", name: "Plugin"),
            ],
            foreground: ["com.hnc.Discord": .init(name: "Discord")],
            named: ["com.hnc.Discord": .init(name: "Discord")])
        #expect(apps.count == 1)
        #expect(apps[0].processCount == 4)
        #expect(apps[0].processIDs.sorted() == [1, 2, 3, 4])
        #expect(!apps[0].isBackground)
    }

    /// The bug this file exists to keep fixed. `afplay`, mpv, ffplay and every
    /// script anybody writes have no bundle identifier, and the list used to
    /// drop them — including while they were the only thing making noise.
    @Test("a playing process with no bundle identifier is still offered")
    func bundlelessPlayingProcess() {
        let apps = AudioApplications.group(
            processes: [
                process(7, pid: 638, bundle: nil, name: "afplay", playing: true),
                process(8, pid: 639, bundle: "", name: "empty", playing: true),
                process(9, pid: 640, bundle: nil, name: "silent daemon"),
            ],
            foreground: [:], named: [:])
        #expect(apps.count == 2)
        // Whatever is playing sorts first, and can be captured: the identity is
        // what the capture set keys on and the object is what the tap is built
        // from, so both have to survive.
        #expect(apps[0].isPlaying)
        #expect(apps[0].bundleID == AudioApplications.identity(forPID: 638))
        #expect(apps[0].name == "afplay")
        #expect(apps[0].processIDs == [7])
        #expect(apps[0].isBackground)
        // The silent unnameable tail stays out of the list.
        #expect(!apps.contains { $0.name == "silent daemon" })
    }

    /// The defect that followed from the rule above, and cost more than it did.
    ///
    /// A bundle-less process is listed only while the HAL says it is running
    /// output, and that property blinks. Measured against afplay playing one
    /// continuous 60-second tone, audible throughout: 0 for 22 of 24 samples a
    /// quarter of a second apart in one run, 1 for all 60 in another. The router
    /// re-reads this list from inside the restart that adds the tap, so a player
    /// the user had just ticked resolved to nothing, no tap was built, and the
    /// mix carried the microphone alone with nothing said about it.
    @Test("something already captured survives a moment of silence")
    func capturedProcessSurvivesTheBlink() {
        let identity = AudioApplications.identity(forPID: 638)
        let processes = [
            // The same player, one blink later: still there, still alive, and
            // reported as making nothing.
            process(7, pid: 638, bundle: nil, name: "afplay", playing: false),
            process(9, pid: 640, bundle: nil, name: "silent daemon"),
        ]
        // Without the tick it is indistinguishable from the daemon, and that is
        // still right: the list is not a process monitor.
        #expect(
            AudioApplications.group(processes: processes, foreground: [:], named: [:]).isEmpty)

        let apps = AudioApplications.group(
            processes: processes, foreground: [:], named: [:], keeping: [identity])
        #expect(apps.count == 1)
        #expect(apps[0].bundleID == identity)
        // The object the tap is built from is the whole point of keeping it.
        #expect(apps[0].processIDs == [7])
        // Honest about what it is doing, which is nothing at this instant.
        #expect(!apps[0].isPlaying)
        // Whatever name the entry arrived with is carried through. The live
        // half of that is in `entry(for:)`, which now resolves an executable
        // name for any process with no bundle rather than only an audible one —
        // otherwise this row would read "afplay" one second and "PID 638" the
        // next, which is the same blink wearing a different hat.
        #expect(apps[0].name == "afplay")
        // Keeping one does not keep the tail with it.
        #expect(!apps.contains { $0.name == "silent daemon" })
    }

    /// The `pid:` prefix is what keeps a synthetic identity out of the prefix
    /// matching. If one could be swallowed by a real bundle identifier, or
    /// swallow one, a tap would end up on the wrong process.
    @Test("a synthetic identity cannot collide with a real one")
    func syntheticIdentityIsDistinct() {
        let identity = AudioApplications.identity(forPID: 42)
        #expect(identity == "pid:42")
        #expect(identity.hasPrefix(AudioApplications.pidIdentityPrefix))
        // No bundle identifier can produce this, and it can never be the prefix
        // of one: the matching only ever appends a dot.
        #expect(!identity.contains("."))
        let apps = AudioApplications.group(
            processes: [
                process(1, pid: 42, bundle: nil, name: "mpv", playing: true),
                process(2, pid: 43, bundle: "com.apple.Safari", name: "Safari", playing: true),
            ],
            foreground: ["com.apple.Safari": .init(name: "Safari")],
            named: ["com.apple.Safari": .init(name: "Safari")])
        #expect(apps.count == 2)
        #expect(Set(apps.map(\.bundleID)) == ["pid:42", "com.apple.Safari"])
        #expect(apps.allSatisfy { $0.processCount == 1 })
    }

    /// Playing first, then the applications, then the daemons — because the
    /// first row is the one somebody is looking for.
    @Test("the order is playing, then foreground, then name")
    func ordering() {
        let apps = AudioApplications.group(
            processes: [
                process(1, pid: 1, bundle: "com.apple.assistantd", name: "assistantd"),
                process(2, pid: 2, bundle: "com.spotify.client", name: "Spotify"),
                process(3, pid: 3, bundle: "com.apple.Safari", name: "Safari"),
                process(
                    4, pid: 4, bundle: "com.apple.audiomxd", name: "audiomxd", playing: true),
            ],
            foreground: [
                "com.spotify.client": .init(name: "Spotify"),
                "com.apple.Safari": .init(name: "Safari"),
            ],
            named: [
                "com.spotify.client": .init(name: "Spotify"),
                "com.apple.Safari": .init(name: "Safari"),
            ])
        #expect(apps.map(\.name) == ["audiomxd", "Safari", "Spotify", "assistantd"])
        #expect(apps[0].isPlaying && apps[0].isBackground)
    }

    /// An accessory has no Dock icon and cannot head a group, which is not a
    /// reason to show `com.apple.controlcenter` where a name would do.
    @Test("an accessory keeps its name and stays in the background")
    func accessoryKeepsItsName() {
        let apps = AudioApplications.group(
            processes: [
                process(1, pid: 1, bundle: "com.apple.controlcenter", name: "controlcenter")
            ],
            foreground: [:],
            named: ["com.apple.controlcenter": .init(name: "控制中心")])
        #expect(apps.count == 1)
        #expect(apps[0].name == "控制中心")
        #expect(apps[0].isBackground)
    }

    /// Safari's GPU process is `com.apple.WebKit.GPU`, which no running
    /// application claims — so it folds on the "helper" rule instead.
    @Test("a helper whose parent is not running folds on its own name")
    func orphanHelper() {
        let apps = AudioApplications.group(
            processes: [
                process(
                    1, pid: 1, bundle: "com.apple.WebKit.helper.GPU",
                    name: "Safari Graphics and Media")
            ],
            foreground: [:], named: [:])
        #expect(apps.count == 1)
        #expect(apps[0].bundleID == "com.apple.WebKit")
    }

    /// Anything the interface can name, the command line has to be able to name
    /// too — and they disagreed. `grouped()` resolves an executable name for a
    /// process that publishes no bundle identifier; every command that matched
    /// on `AudioProcess.name` directly saw "PID 69200" instead. Measured with
    /// one `afplay` playing a tone: `yunaudio-cli apps` listed "afplay",
    /// `yunaudio-cli tap afplay` answered `no process matching "afplay"`, and
    /// the only way to reach it was to type its process id.
    ///
    /// Stated against this very process. `proc_pidpath` answers for any live
    /// process id, so the case needs no player and no waiting: the test runner
    /// publishes no bundle identifier, which is exactly the shape that was
    /// going wrong. The first version did spawn a player and wait for the HAL
    /// to notice it, and failed two runs in four inside a full test run — a
    /// flaky gate is worse than no gate.
    @Test("everything the interface can name, a command line can name too")
    func matchingAgreesWithTheListedName() throws {
        let mine = getpid()
        let halName = "PID \(mine)"
        let executable = AudioApplications.displayName(
            bundleID: nil, pid: mine, halName: halName)
        #expect(executable != halName)
        #expect(!executable.isEmpty)
        #expect(
            AudioApplications.matches(executable, bundleID: nil, pid: mine, halName: halName))
        // The process id still works, and is the only unambiguous handle when
        // two copies of one executable are running.
        #expect(
            AudioApplications.matches(String(mine), bundleID: nil, pid: mine, halName: halName))
        #expect(
            !AudioApplications.matches("Discord", bundleID: nil, pid: mine, halName: halName))
        // A process that does publish one keeps the name that was resolved from
        // the running-application list, which is the one a person recognises.
        #expect(
            AudioApplications.displayName(
                bundleID: "com.hnc.Discord", pid: mine, halName: "Discord") == "Discord")

        // And the general form of it, against whatever is running: every row
        // the interface offers is reachable by the name it shows.
        let processes = try AudioProcesses.all(includingSilent: true)
        var byID: [AudioObjectID: AudioProcess] = [:]
        for process in processes where byID[process.id] == nil { byID[process.id] = process }
        for application in try AudioApplications.grouped() {
            let members = application.processIDs.compactMap { byID[$0] }
            guard !members.isEmpty else { continue }
            #expect(
                members.contains { AudioApplications.matches(application.name, process: $0) },
                "the interface lists \"\(application.name)\" and no process matches that")
        }
    }
}

// MARK: - Aggregate members

/// What the HAL is told about each member is a dictionary of string keys, which
/// is to say it is the one place in this project where a typo compiles, runs,
/// and is silently ignored. The device still builds; it just quietly does not
/// do the thing that was asked for.
@Suite("Aggregate sub-devices")
struct SubDeviceDescriptionTests {

    @Test("drift compensation carries its quality with it")
    func driftQuality() {
        let on = AggregateDevice.SubDevice(uid: "a", driftCompensation: true).description
        #expect(on[kAudioSubDeviceDriftCompensationKey] as? Int == 1)
        #expect(
            on[kAudioSubDeviceDriftCompensationQualityKey] as? Int
                == Int(kAudioAggregateDriftCompensationMaxQuality))

        let off = AggregateDevice.SubDevice(uid: "a", driftCompensation: false).description
        #expect(off[kAudioSubDeviceDriftCompensationKey] as? Int == 0)
    }

    /// The key that stops a Bluetooth headset dropping to HFP. Zero has to
    /// survive into the dictionary as zero — an implementation that treated it
    /// as "nothing to say" would leave the input open and the whole device
    /// would degrade, with the code looking right.
    @Test("no input channels means no input channels, not no opinion")
    func zeroInputChannels() {
        let entry = AggregateDevice.SubDevice(
            uid: "airpods", driftCompensation: true, inputChannels: 0
        ).description
        #expect(entry[kAudioSubDeviceInputChannelsKey] as? Int == 0)
    }

    /// And saying nothing has to stay silent, because the HAL's default is
    /// "all of them" and writing a number in would cap a device that should
    /// have been left alone.
    @Test("saying nothing about channels writes nothing")
    func unrestricted() {
        let entry = AggregateDevice.SubDevice(uid: "a", driftCompensation: true).description
        #expect(entry[kAudioSubDeviceInputChannelsKey] == nil)
        #expect(entry[kAudioSubDeviceOutputChannelsKey] == nil)
        #expect(entry[kAudioSubDeviceExtraOutputLatencyKey] == nil)
    }

    @Test("a latency trim is passed on in frames")
    func latencyTrim() {
        let entry = AggregateDevice.SubDevice(
            uid: "speakers", driftCompensation: true, extraOutputLatencyFrames: 240
        ).description
        #expect(entry[kAudioSubDeviceExtraOutputLatencyKey] as? Int == 240)
    }

    @Test("the UID is always there")
    func uid() {
        let entry = AggregateDevice.SubDevice(uid: "device", driftCompensation: false)
            .description
        #expect(entry[kAudioSubDeviceUIDKey] as? String == "device")
    }
}

// MARK: - MIDI

/// A knob is not a button, and the difference is the whole feature. There is no
/// controller plugged into the machine this was written on, so everything that
/// decides what a message *means* is a pure function and everything below drives
/// those directly rather than waiting for hardware that is not there.

@Suite("MIDI message decoding")
struct MIDIDecodingTests {
    @Test("a control change carries its controller, value and channel")
    func controlChange() {
        // Message type 2, group 0, status B, channel 0, controller 7, value 100.
        let message = MIDIMessage.decode(0x20B0_0764)
        #expect(message?.kind == .controlChange(7))
        #expect(message?.value == 100)
        #expect(message?.channel == 0)
        #expect(message?.isOn == true)
    }

    @Test("the channel is read, not assumed")
    func channel() {
        #expect(MIDIMessage.decode(0x20B5_0764)?.channel == 5)
        #expect(MIDIMessage.decode(0x209F_3C7F)?.channel == 15)
    }

    @Test("a note-on is on and a note-off is not")
    func notes() {
        let on = MIDIMessage.decode(0x2090_3C7F)
        #expect(on?.kind == .note(60))
        #expect(on?.value == 127)
        #expect(on?.isOn == true)

        let off = MIDIMessage.decode(0x2080_3C40)
        #expect(off?.kind == .note(60))
        #expect(off?.isOn == false)
    }

    /// Most keyboards never send status 8 at all. A pad bound to mute would
    /// stick down for ever if the release were read as another press.
    @Test("a note-on with velocity zero is a release")
    func zeroVelocityRelease() {
        #expect(MIDIMessage.decode(0x2090_3C00)?.isOn == false)
    }

    @Test("the bend wheel is fourteen bits, least significant first")
    func pitchBend() {
        // Centre: least significant 0, most significant 64 → 8192.
        #expect(MIDIMessage.decode(0x20E0_0040)?.value == 8192)
        #expect(MIDIMessage.decode(0x20E0_7F7F)?.value == 16383)
        #expect(MIDIMessage.decode(0x20E0_0000)?.value == 0)
        // And it scales over the wider range rather than over 127.
        let centre = MIDIMessage.decode(0x20E0_0040)
        #expect(abs((centre?.position ?? 0) - 0.5) < 0.001)
    }

    /// Only MIDI 1.0 channel voice messages are asked for, because the input
    /// port is opened with that protocol and CoreMIDI translates everything
    /// else down to it. Anything else on the wire is somebody else's business.
    @Test("a packet that is not a channel voice message is refused")
    func otherMessageTypes() {
        #expect(MIDIMessage.decode(0x0000_0000) == nil)  // utility
        #expect(MIDIMessage.decode(0x1000_00F8) == nil)  // system realtime
        #expect(MIDIMessage.decode(0x40B0_0700) == nil)  // MIDI 2.0 channel voice
        #expect(MIDIMessage.decode(0x20C0_0500) == nil)  // programme change
    }

    @Test("every message survives a trip through the wire format")
    func roundTrip() {
        let messages: [MIDIMessage] = [
            .cc(7, 100), .cc(74, 0, channel: 9), .note(36, velocity: 127),
            MIDIMessage(channel: 3, kind: .note(48), value: 64, isOn: false),
            MIDIMessage(channel: 0, kind: .pitchBend, value: 8192, isOn: true),
        ]
        for message in messages {
            #expect(MIDIMessage.decode(message.word) == message)
        }
    }
}

@Suite("MIDI levels")
struct MIDIScaleTests {
    /// The number that matters: a controller at a given value has to land on
    /// the decibel the fader beside it would show, or the two disagree and one
    /// of them is lying about the level.
    @Test("a controller value maps to the decibel the fader would read")
    func decibels() {
        #expect(MIDIScale.decibels(fromPosition: MIDIMessage.cc(7, 0).position) == -40)
        #expect(MIDIScale.decibels(fromPosition: MIDIMessage.cc(7, 127).position) == 12)
        // 64/127 of a 52 dB range above −40 dB.
        let middle = MIDIScale.decibels(fromPosition: MIDIMessage.cc(7, 64).position)
        #expect(abs(middle - (-13.7953)) < 0.001)
        // And unity is where the fader's own tick is, near enough to read as 0.
        let unity = MIDIScale.decibels(fromPosition: MIDIMessage.cc(7, 98).position)
        #expect(abs(unity) < 0.2)
    }

    @Test("out of range positions are clamped rather than extrapolated")
    func clamping() {
        #expect(MIDIScale.decibels(fromPosition: -1) == -40)
        #expect(MIDIScale.decibels(fromPosition: 2) == 12)
        #expect(MIDIScale.position(fromDecibels: -80) == 0)
        #expect(MIDIScale.position(fromDecibels: 40) == 1)
    }

    @Test("decibels and positions are inverses")
    func inverse() {
        for value in stride(from: Float(-40), through: 12, by: 4) {
            let round = MIDIScale.decibels(
                fromPosition: MIDIScale.position(fromDecibels: value))
            #expect(abs(round - value) < 0.001)
        }
    }

    /// The scale is written out rather than taken from the model, whose copy is
    /// main-actor isolated and cannot be a default value. Asserted equal so the
    /// pair cannot drift apart in silence.
    @MainActor
    @Test("the bottom of the MIDI range is the bottom of the fader's")
    func agreesWithTheFader() {
        #expect(MIDIScale.decibels.lowerBound == RouterModel.minimumDecibels)
    }
}

@Suite("MIDI soft takeover")
struct MIDIPickupTests {
    /// −6 dB as a controller position, which is where the software fader sits
    /// in every case below.
    private let software = MIDIScale.position(fromDecibels: -6)

    @Test("a fader arriving at the bottom does not slam the level")
    func doesNotJump() {
        var pickup = MIDIPickup()
        #expect(MIDIPickup.resolve(control: 0, software: software, state: &pickup) == nil)
        #expect(!pickup.isEngaged)
    }

    @Test("and moving towards the value without reaching it still does nothing")
    func stillSuppressed() {
        var pickup = MIDIPickup()
        for control: Float in [0, 0.2, 0.4, 0.6] {
            #expect(
                MIDIPickup.resolve(control: control, software: software, state: &pickup)
                    == nil)
        }
        #expect(!pickup.isEngaged)
    }

    @Test("passing through the software value takes over, and then it follows")
    func picksUp() {
        var pickup = MIDIPickup()
        _ = MIDIPickup.resolve(control: 0.6, software: software, state: &pickup)
        // 0.6 is below −6 dB and 0.7 is above it, so this message swept across.
        #expect(MIDIPickup.resolve(control: 0.7, software: software, state: &pickup) == 0.7)
        #expect(pickup.isEngaged)
        // From here the hardware leads, in both directions.
        #expect(MIDIPickup.resolve(control: 0.9, software: 0.7, state: &pickup) == 0.9)
        #expect(MIDIPickup.resolve(control: 0.1, software: 0.9, state: &pickup) == 0.1)
    }

    @Test("landing on the value takes over without having to cross it")
    func landsOnIt() {
        var pickup = MIDIPickup()
        #expect(
            MIDIPickup.resolve(control: software, software: software, state: &pickup)
                == software)
    }

    /// A seven-bit control cannot land closer than one step to an arbitrary
    /// software position, so "passes through" has to mean "within a step" or a
    /// fader at −6.3 dB could never be picked up at all.
    @Test("one controller step away is close enough")
    func withinAStep() {
        var pickup = MIDIPickup()
        let nearest = (software * 127).rounded() / 127
        #expect(
            MIDIPickup.resolve(control: nearest, software: software, state: &pickup) != nil)
    }

    @Test("dragging the fader on screen makes the hardware catch up again")
    func releasedByTheInterface() {
        var pickup = MIDIPickup()
        _ = MIDIPickup.resolve(control: 0.6, software: software, state: &pickup)
        _ = MIDIPickup.resolve(control: 0.7, software: software, state: &pickup)
        #expect(pickup.isEngaged)
        // Somebody drags the on-screen fader down to 0.2. The knob is still at
        // 0.7, so it is no longer in charge and has to cross 0.2 to get back.
        #expect(MIDIPickup.resolve(control: 0.75, software: 0.2, state: &pickup) == nil)
        #expect(!pickup.isEngaged)
        #expect(MIDIPickup.resolve(control: 0.5, software: 0.2, state: &pickup) == nil)
        #expect(MIDIPickup.resolve(control: 0.15, software: 0.2, state: &pickup) == 0.15)
    }
}

@Suite("MIDI actions")
struct MIDIActionTests {
    private let button = MIDITarget.command(url: "yunaudio://mute")

    @Test("a note-off does not trigger")
    func noteOff() {
        var pickup = MIDIPickup()
        let release = MIDIMessage(channel: 0, kind: .note(36), value: 64, isOn: false)
        #expect(
            MIDIAction.decide(
                for: release, target: button, softwarePosition: 0, pickup: &pickup)
                == .ignore)
    }

    @Test("and neither does the note-on with velocity zero that stands in for one")
    func zeroVelocity() {
        var pickup = MIDIPickup()
        #expect(
            MIDIAction.decide(
                for: .note(36, velocity: 0), target: button, softwarePosition: 0,
                pickup: &pickup) == .ignore)
    }

    @Test("a note-on presses")
    func noteOn() {
        var pickup = MIDIPickup()
        #expect(
            MIDIAction.decide(
                for: .note(36, velocity: 100), target: button, softwarePosition: 0,
                pickup: &pickup) == .press)
    }

    /// A footswitch sends 127 on the way down and 0 on the way up. Acting on
    /// both would make every press a press and a release, which for a toggle is
    /// no press at all.
    @Test("a switch on a button acts on the way down only")
    func switchedController() {
        var pickup = MIDIPickup()
        #expect(
            MIDIAction.decide(
                for: .cc(64, 127), target: button, softwarePosition: 0, pickup: &pickup)
                == .press)
        #expect(
            MIDIAction.decide(
                for: .cc(64, 0), target: button, softwarePosition: 0, pickup: &pickup)
                == .ignore)
    }

    @Test("a knob on a level waits for pickup and then moves it")
    func knobOnALevel() {
        var pickup = MIDIPickup()
        let software = MIDIScale.position(fromDecibels: -6)
        #expect(
            MIDIAction.decide(
                for: .cc(7, 0), target: .fader(.master), softwarePosition: software,
                pickup: &pickup) == .ignore)
        let taken = MIDIAction.decide(
            for: .cc(7, 127), target: .fader(.master), softwarePosition: software,
            pickup: &pickup)
        #expect(taken == .setPosition(1))
        // Which is the top of the fader, not merely the top of the controller.
        if case .setPosition(let position) = taken {
            #expect(MIDIScale.decibels(fromPosition: position) == 12)
        }
    }
}

@Suite("MIDI bindings")
struct MIDIBindingTests {
    @Test("every kind of target and address survives being written and read back")
    func storageRoundTrip() {
        let targets: [MIDITarget] = [
            .fader(.master), .fader(.input), .fader(.monitor),
            .sourceFader(uid: "AppleUSBAudioEngine:Razer:Seiren"),
            .sourceMute(uid: "AppleUSBAudioEngine:Razer:Seiren"),
            .command(url: "yunaudio://mute"),
            .command(url: "yunaudio://preset/Voice%20call"),
        ]
        for target in targets {
            #expect(MIDITarget(storageKey: target.storageKey) == target)
        }

        let addresses: [MIDIAddress] = [
            MIDIAddress(channel: 0, kind: .controlChange(7)),
            MIDIAddress(channel: 15, kind: .note(36)),
            MIDIAddress(channel: 9, kind: .pitchBend),
        ]
        for address in addresses {
            #expect(MIDIAddress(storageKey: address.storageKey) == address)
        }
    }

    @Test("a key this version does not understand is dropped, not guessed at")
    func refusedStorage() {
        #expect(MIDITarget(storageKey: "fader:tilt") == nil)
        #expect(MIDITarget(storageKey: "nonsense") == nil)
        #expect(MIDITarget(storageKey: "command:") == nil)
        // A command the URL scheme does not answer to would sit in the window
        // looking bound and doing nothing.
        #expect(MIDITarget(storageKey: "command:yunaudio://explode") == nil)
        #expect(MIDIAddress(storageKey: "0.cc.999") == nil)
        #expect(MIDIAddress(storageKey: "99.cc.7") == nil)
        #expect(MIDIAddress(storageKey: "0.aftertouch.7") == nil)
    }

    /// The list of things a pad can do and the list a Stream Deck key can do
    /// have to be one list, which means the URL a binding stores has to be a
    /// URL the scheme actually parses.
    @Test("every bindable command round-trips through its own URL")
    func commandsAreURLs() {
        for command in RemoteCommand.bindable {
            #expect(RemoteCommand.parse(command.url) == command)
            let target = MIDITarget.command(url: command.url.absoluteString)
            #expect(MIDITarget(storageKey: target.storageKey) == target)
        }
        // Including the ones with a space in the name, which is where a URL
        // built by hand goes wrong.
        #expect(
            RemoteCommand.parse(RemoteCommand.preset("Voice call").url)
                == .preset("Voice call"))
    }

    @MainActor
    @Test("one message cannot drive two things")
    func exclusive() {
        let controller = MIDIController()
        let address = MIDIAddress(channel: 0, kind: .controlChange(7))
        controller.bind(address, to: .fader(.master))
        controller.bind(address, to: .fader(.input))
        #expect(controller.binding(for: .fader(.master)) == nil)
        #expect(controller.binding(for: .fader(.input)) == address)
        #expect(Set(controller.bindings.values).count == controller.bindings.count)
    }

    @MainActor
    @Test("bindings survive being written down and read back")
    func persistence() {
        let controller = MIDIController()
        controller.bind(
            MIDIAddress(channel: 0, kind: .controlChange(7)), to: .fader(.master))
        controller.bind(
            MIDIAddress(channel: 2, kind: .note(36)), to: .command(url: "yunaudio://mute"))
        controller.bind(
            MIDIAddress(channel: 0, kind: .controlChange(8)),
            to: .sourceFader(uid: "BuiltInMicrophoneDevice"))
        let stored = controller.storedBindings

        let restored = MIDIController()
        restored.restore(stored)
        #expect(restored.bindings == controller.bindings)

        // And through the file the application actually writes, because a
        // dictionary that round-trips in memory and not through JSON is a
        // binding that silently vanishes on the next launch.
        var preferences = Preferences.default
        preferences.midiBindings = stored
        let data = try? JSONEncoder().encode(preferences)
        let decoded = data.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
        #expect(decoded?.midiBindings == stored)
    }

    /// A preferences file can be edited by hand, or written by a version that
    /// allowed something this one does not. Two targets claiming one control
    /// must not survive the trip back in.
    @MainActor
    @Test("a duplicate in the file is dropped on the way in")
    func duplicatesOnRestore() {
        let controller = MIDIController()
        controller.restore(["fader:master": "0.cc.7", "fader:input": "0.cc.7"])
        #expect(controller.bindings.count == 1)
        #expect(Set(controller.bindings.values).count == 1)
    }

    @MainActor
    @Test("a freshly learned fader is bound and does nothing yet")
    func learnedFadersWait() {
        let controller = MIDIController()
        controller.learningTarget = .fader(.master)
        controller.receive(.cc(7, 100))
        #expect(controller.learningTarget == nil)
        #expect(
            controller.binding(for: .fader(.master))
                == MIDIAddress(channel: 0, kind: .controlChange(7)))
        // Bound, and holding back until the knob passes the level — which is
        // the point of the whole thing.
        #expect(!controller.isEngaged(.fader(.master)))
    }
}

// MARK: - What the preferences file promises

/// The preferences blob is a promise to a copy of the application that has not
/// been built yet, and every way it can fail is silent: a field nobody writes,
/// a field nobody reads, or a type change that makes the whole file undecodable
/// and drops every setting at once.
///
/// `tapMuteBehavior` was the first kind. Its `didSet` had called `persist()`
/// since the day it was written and `Preferences` had no field for it, so the
/// setting deciding whether a captured application stays audible was forgotten
/// at every launch.
@Suite("Preferences round trip")
struct PreferencesRoundTripTests {

    @Test("every tap mute behaviour survives being written down")
    func tapMuteBehaviourRoundTrip() {
        for behaviour in TapMuteBehavior.allCases {
            #expect(TapMuteBehavior(storageKey: behaviour.storageKey) == behaviour)
        }
        // Distinct, or two of them would collapse into one on the way back in.
        #expect(
            Set(TapMuteBehavior.allCases.map(\.storageKey)).count
                == TapMuteBehavior.allCases.count)
    }

    @Test("a name this version has never seen is refused rather than guessed")
    func unknownStorageKey() {
        #expect(TapMuteBehavior(storageKey: "mutedOnAlternateTuesdays") == nil)
    }

    @Test("the whole blob survives an encode and decode")
    func blobRoundTrip() throws {
        var preferences = Preferences.default
        preferences.tapMuteBehavior = TapMuteBehavior.mutedWhenTapped.storageKey
        preferences.sourceDeviceUID = "a-source"
        preferences.effectValues = ["gate.threshold": -38]
        preferences.iconStyle = "paper"
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded == preferences)
        #expect(decoded.iconStyle == "paper")
    }

    /// Every name the icon picker can write has to be a name the next launch
    /// can read. The picker is built from the same list, so the way this fails
    /// is a style being *removed*: the file then names something that no longer
    /// exists, and an icon that cannot be drawn is a blank tile rather than an
    /// error.
    @Test("every icon style survives being written down, and a dropped one falls back")
    func iconStyleRoundTrip() throws {
        for style in YunIconBadge.styles {
            var preferences = Preferences.default
            preferences.iconStyle = style.name
            let data = try JSONEncoder().encode(preferences)
            let decoded = try JSONDecoder().decode(Preferences.self, from: data)
            #expect(YunIconBadge.style(named: decoded.iconStyle).name == style.name)
        }
        #expect(
            YunIconBadge.style(named: "a-style-this-build-dropped").name
                == YunIconBadge.fallbackStyle)
    }

    /// The reason every field added since the first release is optional: a file
    /// written by an older copy has none of them, and one non-optional addition
    /// would fail the whole decode and take every setting with it.
    @Test("a file written before a field existed still decodes")
    func forwardCompatibility() throws {
        let legacy = """
            {"channelMode":"mono","monoChannel":0,"bufferFrames":128,"autoStart":false,
             "voiceIsolationEnabled":false,"voiceIsolationMix":100,
             "preferredSampleRate":48000,"capturedAppBundleIDs":[],
             "enabledEffects":[],"effectValues":{}}
            """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
        #expect(decoded.bufferFrames == 128)
        // Absent rather than defaulted here: the model supplies the default on
        // the way in, and a decode that invented one would hide a field nobody
        // is writing — which is the failure this suite exists for.
        #expect(decoded.tapMuteBehavior == nil)
        #expect(decoded.midiBindings == nil)
    }
}

/// Which channel of a source the application starts on.
///
/// This existed as four lines inside a private method that could not run. The
/// method is called from exactly one place that matters — the first launch,
/// before anybody has chosen anything — and that call sat inside `restore()`,
/// which holds `isRestoring` for its whole body, and the first line of the
/// method was `guard !isRestoring`. So on a fresh install the rule never ran:
/// every device got mono on channel 0, and a two-channel interface sent one
/// side of every call into silence until somebody found the control.
///
/// It went unnoticed because the machine it was written on has a Seiren V3
/// Pro, whose right answer *is* mono on channel 0.
@MainActor
@Suite("Which channel to start on")
struct ChannelDefaultTests {

    @Test("an odd channel count is never treated as a stereo pair")
    func oddCountsAreMono() {
        for count in [1, 3, 5, 7] {
            let choice = RouterModel.defaultChannelChoice(inputChannels: count, names: nil)
            #expect(choice.mode == SourceChannelMode.mono, "\(count) channels")
            #expect(choice.channel == 0)
        }
    }

    @Test("an even count of two or more is a stereo pair")
    func evenCountsAreStereo() {
        for count in [2, 4, 6, 8] {
            let choice = RouterModel.defaultChannelChoice(inputChannels: count, names: nil)
            #expect(choice.mode == SourceChannelMode.stereo, "\(count) channels")
        }
    }

    /// Zero and the nonsense below it: a device with no inputs cannot be a
    /// stereo pair, and the arithmetic says even.
    @Test("nothing to route is mono rather than stereo")
    func zeroIsMono() {
        #expect(
            RouterModel.defaultChannelChoice(inputChannels: 0, names: nil).mode
                == SourceChannelMode.mono)
    }

    /// A device that publishes its own topology overrules the count, and it is
    /// the reason this is worth a rule at all: the Seiren V3 Pro reports three
    /// inputs and says which one is the capsule.
    @Test("a device that names its channels decides for itself")
    func namesWin() {
        let names = [
            DeviceChannelNames.Channel(name: "Dry", detail: "", isDefault: false),
            DeviceChannelNames.Channel(name: "Processed", detail: "", isDefault: true),
            DeviceChannelNames.Channel(name: "Post-expander", detail: "", isDefault: false),
        ]
        let choice = RouterModel.defaultChannelChoice(inputChannels: 3, names: names)
        #expect(choice.mode == SourceChannelMode.mono)
        #expect(choice.channel == 1)
        // And it wins over an even count, which would otherwise say stereo.
        let pair = [
            DeviceChannelNames.Channel(name: "A", detail: "", isDefault: false),
            DeviceChannelNames.Channel(name: "B", detail: "", isDefault: true),
        ]
        let paired = RouterModel.defaultChannelChoice(inputChannels: 2, names: pair)
        #expect(paired.mode == SourceChannelMode.mono)
        #expect(paired.channel == 1)
    }

    /// Names with nothing marked fall back to the count rather than to channel
    /// zero, which is the case a device with a plain list of names produces.
    @Test("names with no default fall back to the count")
    func namesWithoutADefault() {
        let names = (0..<2).map {
            DeviceChannelNames.Channel(name: "In \($0)", detail: "", isDefault: false)
        }
        #expect(
            RouterModel.defaultChannelChoice(inputChannels: 2, names: names).mode
                == SourceChannelMode.stereo)
    }
}

/// How wide a captured application's tap arrives, which decides how many routes
/// it contributes — and therefore whether it is on the bus at all.
@MainActor
@Suite("How much of a tap gets routed")
struct TapChannelTests {

    @Test("a tap is as wide as it says, up to the destination")
    func widthFollowsTheTap() {
        #expect(RouterModel.channelsToRoute(published: 2, destination: 2) == 2)
        #expect(RouterModel.channelsToRoute(published: 1, destination: 2) == 1)
        // A wider tap than the destination can take is narrowed, not refused.
        #expect(RouterModel.channelsToRoute(published: 6, destination: 2) == 2)
    }

    /// The trap: absent and present-but-zero are different answers, and `?? 2`
    /// only sees the first. A published zero produced no routes and no message,
    /// which reads from every meter as a tap that is merely quiet.
    @Test("a tap that publishes nothing, or nothing useful, is taken as stereo")
    func silenceAboutTheFormatIsStereo() {
        #expect(RouterModel.channelsToRoute(published: nil, destination: 2) == 2)
        #expect(RouterModel.channelsToRoute(published: 0, destination: 2) == 2)
    }

    /// A destination with nowhere to put it is the one case that is honestly
    /// nothing, and it must not be confused with the two above.
    @Test("a destination with no channels carries none of it")
    func noDestinationCarriesNothing() {
        #expect(RouterModel.channelsToRoute(published: 2, destination: 0) == 0)
    }
}

/// The menu bar mark, which is the only part of this application somebody is
/// looking at while they are on a call.
///
/// It has four states and they have to be distinguishable at eighteen points:
/// idle, routing at some level, muted, and muted while the system's own
/// detector can hear somebody speaking. The last is the one worth the drawing —
/// the window can say "muted, but talking" all it likes, and nobody is looking
/// at the window.
///
/// The whole mark is monochrome, because a status item is a *template* image:
/// macOS renders it in the menu bar's own foreground colour, so it follows light
/// and dark mode and inverts under an open menu — and only the alpha channel
/// survives that. Every claim below is about alpha and geometry for that reason,
/// and the "no colour" test is what stops the states quietly going back to being
/// a red dot and a green one.
///
/// Asserted as pixels rather than by eye. "These two look different" is exactly
/// the kind of claim that is obviously true until a badge one point larger
/// turns out to be no difference at all.
@MainActor
@Suite("The menu bar mark")
struct StatusMarkTests {

    /// Rendered into a bitmap of our own making rather than taken off the
    /// `NSImage`: a drawing-handler image promises nothing about the size or
    /// colour space of `tiffRepresentation`, and every assertion here is about
    /// individual pixels. Drawn at 2× because that is what the menu bar
    /// actually asks for on every display this application has ever run on.
    private static let scale = 2
    private static let side = 18 * scale

    private func render(
        level: Float?, isMuted: Bool = false, isSpeakingWhileMuted: Bool = false,
        isDim: Bool = false
    ) throws -> NSBitmapImageRep {
        let side = Self.side
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: side * 4, bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Cleared first. `NSBitmapImageRep(bitmapDataPlanes: nil, …)` hands back
        // whatever was in that allocation, and every assertion here is a sum
        // over the alpha channel — so the measurements were the glyph plus
        // whatever the last owner of that memory had left in it. It failed five
        // times out of five run on its own and passed in the whole suite, which
        // is the shape of uninitialised memory rather than of a race.
        context.cgContext.clear(
            CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        context.cgContext.scaleBy(x: CGFloat(Self.scale), y: CGFloat(Self.scale))
        StatusItemController.drawStatusMark(
            level: level, isMuted: isMuted, isSpeakingWhileMuted: isSpeakingWhileMuted,
            isDim: isDim)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func bytes(_ rep: NSBitmapImageRep) throws -> Data {
        try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Total alpha over the square, as a fraction. How much ink the glyph puts
    /// on the menu bar.
    private func ink(_ rep: NSBitmapImageRep, in region: NSRect? = nil) throws -> Double {
        let pixels = try #require(rep.bitmapData)
        let region =
            region ?? NSRect(x: 0, y: 0, width: CGFloat(Self.side), height: CGFloat(Self.side))
        var total = 0.0
        for row in Int(region.minY)..<Int(region.maxY) {
            let base = row * rep.bytesPerRow
            for column in Int(region.minX)..<Int(region.maxX) {
                total += Double(pixels[base + column * 4 + 3]) / 255
            }
        }
        return total / (region.width * region.height)
    }

    @Test("it is a template, so the menu bar can colour it")
    func isATemplate() throws {
        for image in [
            StatusItemController.statusImage(level: nil),
            StatusItemController.statusImage(level: 0.5),
            StatusItemController.statusImage(level: nil, isMuted: true),
        ] {
            #expect(try #require(image).isTemplate)
        }
    }

    /// The requirement in the form it can actually fail. A template throws
    /// colour away, so a state drawn in red simply vanishes rather than looking
    /// wrong — which is how the old mark could encode mute as "red" and have
    /// nobody notice that the menu bar never showed red at all.
    @Test("and nothing in it is coloured")
    func nothingIsColoured() throws {
        for (name, rep) in try [
            ("idle", render(level: nil)),
            ("routing", render(level: 0.5)),
            ("muted", render(level: nil, isMuted: true)),
            ("alarmed", render(level: nil, isMuted: true, isSpeakingWhileMuted: true)),
        ] {
            let pixels = try #require(rep.bitmapData)
            var coloured = 0
            for row in 0..<Self.side {
                let base = row * rep.bytesPerRow
                for column in 0..<Self.side {
                    let offset = base + column * 4
                    let r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2]
                    if r != g || g != b { coloured += 1 }
                }
            }
            #expect(coloured == 0, "\(name) has \(coloured) coloured pixels")
        }
    }

    @Test("muted and muted-while-talking are not the same mark")
    func alarmedDiffersFromMuted() throws {
        let muted = try bytes(render(level: nil, isMuted: true))
        // The alarm is a blink, so it differs on the dim half of it. Both halves
        // are checked: one that matched plain mute on *both* would be a warning
        // that never appears.
        let dim = try bytes(
            render(level: nil, isMuted: true, isSpeakingWhileMuted: true, isDim: true))
        let bright = try bytes(
            render(level: nil, isMuted: true, isSpeakingWhileMuted: true, isDim: false))
        #expect(muted != dim)
        #expect(bright != dim)
    }

    /// And the alarm only ever means something alongside a mute. Voice activity
    /// on a live microphone is a meter, not a warning, and drawing it as one
    /// would make the warning meaningless by being on all the time.
    @Test("speaking on a live microphone changes nothing")
    func speakingUnmutedIsNotAWarning() throws {
        let plain = try bytes(render(level: 0.4))
        let same = try bytes(render(level: 0.4, isSpeakingWhileMuted: true, isDim: true))
        #expect(plain == same)
    }

    @Test("every state is drawn, and no two of them look alike")
    func everyStateIsDistinct() throws {
        let states: [(String, NSBitmapImageRep)] = try [
            ("idle", render(level: nil)),
            ("quiet", render(level: 0.02)),
            ("loud", render(level: 0.8)),
            ("muted", render(level: nil, isMuted: true)),
            (
                "alarmed",
                render(level: nil, isMuted: true, isSpeakingWhileMuted: true, isDim: true)
            ),
        ]
        for (index, state) in states.enumerated() {
            #expect(try ink(state.1) > 0.02, "\(state.0) drew almost nothing")
            for other in states.dropFirst(index + 1) {
                #expect(
                    try bytes(state.1) != bytes(other.1),
                    "\(state.0) and \(other.0) are the same picture")
            }
        }
    }

    /// The mark *is* the meter: it fills from the bottom, so more level is more
    /// ink. Asserted on the whole glyph, because there is no longer a second
    /// object to measure — which is the point of the change.
    @Test("the mark fills as the level rises")
    func markFillsWithLevel() throws {
        let quiet = try ink(render(level: 0.02))
        let middling = try ink(render(level: 0.15))
        let loud = try ink(render(level: 0.9))
        #expect(quiet < middling)
        #expect(middling < loud)
    }

    /// The regression this design nearly shipped with. Filling the mark makes a
    /// loud room draw the mark solid — which is exactly what a *stopped* router
    /// drew, so the two states were the same picture. Capping the fill was tried
    /// first and measured: it moved 3.7% of the ink, which at eighteen points is
    /// no difference at all. A stopped router is dimmed instead.
    @Test("a stopped router does not look like a loud one")
    func idleIsNotFullScale() throws {
        let idle = try ink(render(level: nil))
        let loud = try ink(render(level: 1.0))
        #expect(loud - idle > 0.04, "idle \(idle) and full scale \(loud) are too close")

        // And the scale runs the right way round. A first version used a
        // dimmer empty meter than idle mark, so *starting* a route made the
        // icon fainter until somebody spoke — measured at 0.196 against 0.210.
        // One resting level for both makes the fill the only thing that adds
        // light, which is the only arrangement in which more sound is more mark.
        let silent = try ink(render(level: 0))
        #expect(silent > idle, "starting a route made the mark fainter")
        for (quieter, louder) in zip(
            [Float(0), 0.03, 0.1, 0.4], [Float(0.03), 0.1, 0.4, 1.0])
        {
            #expect(
                try ink(render(level: louder)) > ink(render(level: quieter)),
                "\(louder) is not brighter than \(quieter)")
        }
    }

    /// The number the fill turns on, and the reason it is not simply the height.
    ///
    /// The mark is a tapered shape: measured from the artwork, the bottom third
    /// of its height carries about a ninth of its ink. A waterline driven
    /// straight off the level would therefore have crept through the whole
    /// quiet half of the range without lighting anything anybody could see.
    @Test("asking for a third of the mark lit lights a third of it")
    func waterlineIsProportionalToArea() {
        let profile = YunAppIcon.inkProfile
        #expect(profile.count > 2)
        // Monotonic and spanning the whole mark, or the inversion below is
        // reading a broken measurement.
        #expect(profile.first == 0)
        #expect(abs((profile.last ?? 0) - 1) < 0.0001)
        for (below, above) in zip(profile, profile.dropFirst()) {
            #expect(above >= below)
        }
        // The inverse round-trips: the waterline for a share of the ink, read
        // back through the profile, is that share again.
        for target in stride(from: CGFloat(0.1), through: 0.9, by: 0.1) {
            let height = YunAppIcon.waterline(forFilled: target)
            let step = CGFloat(profile.count - 1)
            let index = min(profile.count - 1, Int((height * step).rounded()))
            #expect(
                abs(profile[index] - target) < 0.02,
                "waterline for \(target) lights \(profile[index])")
        }
        // And it really is not the identity — if it were, the measurement had
        // silently fallen back to a straight line and the taper is unaccounted
        // for. Measured: a tenth of the ink needs nearly a third of the height.
        #expect(YunAppIcon.waterline(forFilled: 0.1) > 0.2)
    }

    /// The curve behind the meter, which is the part a picture cannot show.
    ///
    /// The old one reached the top at −12 dBFS — an ordinary speech peak — so a
    /// column driven by it would have stood full through every sentence
    /// anybody said. That was survivable while the level was the opacity of a
    /// dot and is not now.
    @Test("the meter spreads speech across its range instead of pinning")
    func meterCurveSpreadsSpeech() {
        // Peaks a metre from a microphone at a normal speaking volume, roughly
        // −30 to −6 dBFS. Every one of these has to be visibly different from
        // the next, which is the whole job of a meter.
        let speech: [Float] = [0.03, 0.06, 0.12, 0.25, 0.5]
        let intensities = speech.map { StatusItemController.meterIntensity($0) }
        for (quieter, louder) in zip(intensities, intensities.dropFirst()) {
            // A twentieth of the column is a visible step at fourteen points.
            #expect(louder - quieter > 0.05, "\(quieter) and \(louder) are too close")
        }
        #expect(intensities.allSatisfy { $0 > 0 && $0 < 1 }, "speech reaches an end stop")
        // And the ends behave: silence is empty, full scale is full.
        #expect(StatusItemController.meterIntensity(0) == 0)
        #expect(StatusItemController.meterIntensity(1) == 1)
        // A quiet room does not light it at all, or the meter twitches on the
        // noise floor for as long as the application is running.
        #expect(StatusItemController.meterIntensity(0.002) == 0)
    }

    /// The two defects the old glyph had, in the form that can catch them
    /// coming back. Measured: the mark used to sit 1.4 points left of centre
    /// with its ink touching the top edge of the image.
    @Test("the mark is centred and does not touch the edges")
    func markSitsInsideItsBox() throws {
        let rep = try render(level: nil)
        let pixels = try #require(rep.bitmapData)
        var minX = Self.side, maxX = -1, minRow = Self.side, maxRow = -1
        for row in 0..<Self.side {
            let base = row * rep.bytesPerRow
            for column in 0..<Self.side where pixels[base + column * 4 + 3] > 10 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        let scale = Double(Self.scale)
        let centre = (Double(minX) + Double(maxX) + 1) / 2 / scale
        // Within a point of the middle of an eighteen-point square. A point is
        // not something anybody sees at this size; 1.4 of them was.
        #expect(abs(centre - 9) <= 1, "the mark's centre is at \(centre) of 18")
        // Apple's own menu bar symbols keep a margin; a glyph that runs to the
        // edge reads as too large beside them.
        #expect(Double(minRow) / scale >= 1, "no margin above the mark")
        #expect(18 - Double(maxRow + 1) / scale >= 1, "no margin below the mark")
    }

    /// Weight, against the only reference that matters: what Apple puts in the
    /// same menu bar. Too light and it reads as a smudge; too heavy and it is
    /// the loudest thing up there.
    @Test("and it weighs about what Apple's own symbols weigh")
    func inkIsInTheSystemRange() throws {
        // Measured at full strength — a full meter — because that is the mark
        // at its heaviest, and the question is whether it shouts next to the
        // system's own. The dimmed states can only be lighter.
        let full = try ink(render(level: 1.0))
        // Measured across mic, mic.fill, waveform, speaker.wave.2.fill,
        // airpodspro and bolt.horizontal.fill at this size: 0.17 to 0.28.
        #expect(full > 0.12, "the mark is fainter than any system symbol: \(full)")
        #expect(full < 0.32, "the mark is heavier than any system symbol: \(full)")
    }
}

/// The application icon, which is drawn rather than stored.
///
/// The claims worth holding are the ones a wrong number makes invisible: a body
/// that fills its canvas sits proud of every neighbour in the Dock, and a mark
/// that is too small reads as an empty tile. Both were true of the icon this
/// replaced — a 180-point bitmap scaled five-fold into a 1024 slot, with no
/// body at all.
@MainActor
@Suite("The application icon")
struct AppIconTests {

    private func rep(_ size: Int, _ style: String = "graphite") throws -> NSBitmapImageRep {
        try #require(YunIconBadge.bitmap(size: size, style: YunIconBadge.style(named: style)))
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> Double {
        let pixels = try #require(rep.bitmapData)
        return Double(pixels[y * rep.bytesPerRow + x * 4 + 3]) / 255
    }

    @Test("every slot iconutil asks for is produced, at the size it asks for")
    func everySlotIsDrawn() throws {
        for slot in YunIconBadge.iconsetSlots {
            let rep = try rep(slot.pixels)
            #expect(rep.pixelsWide == slot.pixels)
            #expect(rep.pixelsHigh == slot.pixels)
        }
    }

    /// Apple's grid: a body of 824 in a canvas of 1024. The corners must be
    /// empty and the middle of each edge must not be.
    @Test("the body is a rounded shape inside the canvas, not the whole canvas")
    func bodyHasTheSystemMargins() throws {
        let size = 1024
        let rep = try rep(size)
        // A corner of the canvas is outside the body by a wide margin.
        #expect(try alpha(rep, 8, 8) < 0.02)
        #expect(try alpha(rep, size - 9, 8) < 0.02)
        // So is a corner of the body's own bounding box, because the body is
        // rounded. This is what a plain rectangle would fail.
        #expect(try alpha(rep, 104, 104) < 0.5)
        // The middle of each edge of the body is solid.
        #expect(try alpha(rep, size / 2, 104) > 0.98)
        #expect(try alpha(rep, 104, size / 2) > 0.98)
        #expect(try alpha(rep, size / 2, size / 2) > 0.98)
        // And the canvas outside the body is empty apart from the shadow.
        #expect(try alpha(rep, size / 2, 8) < 0.35)
    }

    /// The mark has to be big enough to see at the sizes people actually meet
    /// the icon at. Measured against the body rather than the canvas, since the
    /// canvas is mostly margin.
    @Test("the mark fills most of the body")
    func markIsNotLostInTheBody() throws {
        let height = YunAppIcon.inkBox(height: 1, centredAt: .zero).height
        #expect(height > 0)
        let rep = try rep(1024)
        // Sampled down the vertical centre line of the body: the mark should be
        // present well above and well below the middle.
        let body = (top: 1024 - 100, bottom: 100)
        let span = Double(body.top - body.bottom)
        var covered = 0
        for row in body.bottom..<body.top {
            // Row indices run downwards in a bitmap; the mark is symmetric
            // enough about the centre line for this to be a fair sample.
            if try alpha(rep, 512, row) > 0.02 { covered += 1 }
        }
        let fraction = Double(covered) / span
        #expect(fraction > 0.5, "the mark covers \(fraction) of the body's height")
    }

    @Test("every style builds, and they do not all look the same")
    func stylesDiffer() throws {
        var seen: [Data] = []
        for style in YunIconBadge.styles {
            let rep = try #require(YunIconBadge.bitmap(size: 128, style: style))
            let data = try #require(rep.representation(using: .png, properties: [:]))
            #expect(!seen.contains(data), "\(style.name) is identical to another style")
            seen.append(data)
        }
        #expect(seen.count == YunIconBadge.styles.count)
    }

    /// An unknown name must not silently produce a different icon from the one
    /// asked for — `make-icon.sh --style typo` should build the default, and
    /// that is only safe because the default is a real entry.
    @Test("an unknown style name falls back to one that exists")
    func unknownStyleFallsBack() {
        #expect(YunIconBadge.style(named: "no-such-style").name == YunIconBadge.fallbackStyle)
        #expect(YunIconBadge.style(named: nil).name == YunIconBadge.fallbackStyle)
        #expect(YunIconBadge.styles.contains { $0.name == YunIconBadge.fallbackStyle })
    }
}

/// Where the mark's ink is inside its own file.
///
/// This is measured rather than written down so that replacing the PNG is all
/// somebody has to do to change the application's mark. The test is that the
/// measurement is actually doing something: a bounding box covering the whole
/// file would mean the scan had failed and every placement had quietly gone
/// back to using the file's padding.
@Suite("The mark's ink bounds")
struct InkBoundsTests {

    @Test("the mark is a portrait shape and does not fill its file")
    func inkIsMeasured() {
        let bounds = YunAppIcon.inkBounds
        #expect(bounds.width > 0.2 && bounds.width < 0.9)
        #expect(bounds.height > 0.5)
        // Taller than it is wide — if this ever fails, the artwork changed
        // shape and every box sized from `inkAspect` wants looking at.
        #expect(YunAppIcon.inkAspect < 1)
    }

    @Test("and a box built from it keeps the mark's proportions")
    func boxKeepsTheAspect() {
        let box = YunAppIcon.inkBox(height: 100, centredAt: NSPoint(x: 50, y: 50))
        #expect(box.height == 100)
        #expect(abs(box.width - 100 * YunAppIcon.inkAspect) < 0.001)
        #expect(abs(box.midX - 50) < 0.001)
        #expect(abs(box.midY - 50) < 0.001)
    }
}

/// Device names in the places narrow enough to truncate.
///
/// A middle truncation of "Razer Seiren V2 X" produces "Razer…en V2 X" — it
/// keeps the word every Razer device shares and eats the one that says which
/// device it is. This is the rule that stops it, and it is asserted rather than
/// eyeballed because the failure mode is a name that says nothing.
@Suite("Shortening a device name")
struct ShortDeviceNameTests {

    @Test("the manufacturer's own prefix comes off")
    func dropsTheBrand() {
        #expect(
            AudioDevice.shortName(of: "Razer Seiren V2 X", manufacturer: "Razer Inc")
                == "Seiren V2 X")
        #expect(
            AudioDevice.shortName(of: "Razer Barracuda 2.4", manufacturer: "Razer Inc")
                == "Barracuda 2.4")
    }

    @Test("a name that does not begin with it is left alone")
    func leavesOthersAlone() {
        #expect(
            AudioDevice.shortName(of: "BlackHole 16ch", manufacturer: "Existential Audio")
                == "BlackHole 16ch")
        #expect(
            AudioDevice.shortName(of: "MacBook Pro的麥克風", manufacturer: "Apple Inc.")
                == "MacBook Pro的麥克風")
    }

    /// The case that matters most, because it is the one that would make the
    /// interface worse rather than better.
    @Test("a name that would be left too short keeps its prefix")
    func keepsShortNamesWhole() {
        #expect(AudioDevice.shortName(of: "Razer X", manufacturer: "Razer Inc") == "Razer X")
        #expect(AudioDevice.shortName(of: "Razer", manufacturer: "Razer Inc") == "Razer")
    }

    @Test("no manufacturer means nothing to take off")
    func noManufacturer() {
        #expect(AudioDevice.shortName(of: "Some Device", manufacturer: nil) == "Some Device")
        #expect(AudioDevice.shortName(of: "Some Device", manufacturer: "") == "Some Device")
    }
}

/// The sample rate as it is written on the screen.
///
/// Two places showed the same device at once and disagreed: the status bar said
/// "44.1 kHz" and the settings window said "44 kHz", because one formatted to a
/// decimal where there was one and the other took `Int` of the division. That
/// is not a rounding difference — 44.1 kHz is the name of the rate, and 44 kHz
/// is a rate nothing uses.
@Suite("Writing a sample rate")
struct SampleRateLabelTests {

    @Test("a rate with a fraction keeps it")
    func fractionalRates() {
        #expect(Format.sampleRate(44100) == "44.1 kHz")
        #expect(Format.sampleRate(88200) == "88.2 kHz")
        #expect(Format.sampleRate(176_400) == "176.4 kHz")
    }

    /// And a whole one does not gain a ".0", which reads as a different kind of
    /// number rather than as the same one written more carefully.
    @Test("a whole rate stays whole")
    func wholeRates() {
        #expect(Format.sampleRate(48000) == "48 kHz")
        #expect(Format.sampleRate(96000) == "96 kHz")
        #expect(Format.sampleRate(192_000) == "192 kHz")
        #expect(Format.sampleRate(8000) == "8 kHz")
    }
}

/// How often the menu bar glyph is worth redrawing.
///
/// It was rebuilt twice a second forever — an `NSImage`, locked, drawn into and
/// unlocked — whether or not anything about it had changed. Idle, nothing about
/// it *can* change: with no route running there is no level, so the same
/// eighteen points were redrawn a hundred and seventy thousand times a day to
/// produce the same pixels.
///
/// The rule is asserted rather than the saving, because the saving depends on
/// how loud the room is. What has to be true is that a mark which draws the
/// same is the same, and one that draws differently is not.
@MainActor
@Suite("Redrawing the menu bar mark")
struct StatusMarkChangeTests {

    typealias Mark = StatusItemController.Mark

    /// Idle is the case this exists for: no route, no level, nothing to draw
    /// differently however long anybody waits.
    @Test("nothing running is always the same mark")
    func idleNeverChanges() {
        let first = Mark.of(level: nil, isMuted: false, isSpeakingWhileMuted: false)
        let second = Mark.of(level: nil, isMuted: false, isSpeakingWhileMuted: false)
        #expect(first == second)
        #expect(first.intensity == nil)
    }

    /// A meter jittering in the noise floor must not redraw, or the change
    /// would be a comment rather than a saving.
    @Test("a level moving below one step is the same mark")
    func smallMovesDoNotRedraw() {
        let quiet = Mark.of(level: 0.200, isMuted: false, isSpeakingWhileMuted: false)
        let barely = Mark.of(level: 0.208, isMuted: false, isSpeakingWhileMuted: false)
        #expect(quiet == barely)
    }

    /// And a real move does, or the meter would stop being a meter.
    @Test("a level moving a visible amount is a different mark")
    func realMovesRedraw() {
        let quiet = Mark.of(level: 0.1, isMuted: false, isSpeakingWhileMuted: false)
        let loud = Mark.of(level: 0.8, isMuted: false, isSpeakingWhileMuted: false)
        #expect(quiet != loud)
    }

    @Test("muting is a different mark, and so is talking into a mute")
    func muteStatesDiffer() {
        let live = Mark.of(level: 0.3, isMuted: false, isSpeakingWhileMuted: false)
        let muted = Mark.of(level: 0.3, isMuted: true, isSpeakingWhileMuted: false)
        let alarmed = Mark.of(level: 0.3, isMuted: true, isSpeakingWhileMuted: true)
        #expect(live != muted)
        #expect(muted != alarmed)
    }

    /// Voice activity without a mute changes nothing, matching the drawing —
    /// otherwise the mark would redraw at the rate of speech for no visible
    /// reason.
    @Test("speaking on a live microphone is the same mark")
    func speakingUnmutedIsTheSameMark() {
        let plain = Mark.of(level: 0.3, isMuted: false, isSpeakingWhileMuted: false)
        let speaking = Mark.of(level: 0.3, isMuted: false, isSpeakingWhileMuted: true)
        #expect(plain == speaking)
    }
}

/// The bar on a vertical equaliser band.
///
/// It was filled from the bottom, like a volume control. On a control that cuts
/// as well as boosts that means a flat equaliser draws ten half-full bars —
/// which reads as "these bands are set to something" when the whole point of
/// flat is that they are not, and it contradicts the centre tick drawn
/// immediately behind it, which was already saying where nothing is the right
/// answer. Found by rendering the window and looking at it under a caption that
/// said, in words, 平坦.
@Suite("The bar on an equaliser band")
struct VerticalSliderFillTests {

    private let height = 100.0

    @Test("flat draws nothing at all")
    func flatDrawsNothing() {
        let fill = YunVerticalSlider.fill(for: 0.5, height: height)
        #expect(fill.length == 0)
    }

    /// A boost stands above the centre and a cut hangs below it, and the two
    /// are the same length for the same distance from flat.
    @Test("a boost and a cut of the same size are mirror images")
    func boostAndCutMirror() {
        let boost = YunVerticalSlider.fill(for: 0.75, height: height)
        let cut = YunVerticalSlider.fill(for: 0.25, height: height)
        #expect(boost.length == cut.length)
        #expect(boost.length == 25)
        // The boost starts at the centre and runs up; the cut starts a quarter
        // up and runs to the centre.
        #expect(boost.base == 50)
        #expect(cut.base == 25)
        #expect(cut.base + cut.length == 50)
    }

    @Test("the extremes reach the centre and no further")
    func extremes() {
        let top = YunVerticalSlider.fill(for: 1, height: height)
        #expect(top.base == 50)
        #expect(top.length == 50)
        let bottom = YunVerticalSlider.fill(for: 0, height: height)
        #expect(bottom.base == 0)
        #expect(bottom.length == 50)
    }

    /// Out of range is clamped rather than drawn off the end of the track.
    @Test("a fraction outside 0…1 is clamped")
    func clamped() {
        #expect(YunVerticalSlider.fill(for: 2, height: height).length == 50)
        #expect(YunVerticalSlider.fill(for: -1, height: height).length == 50)
        #expect(YunVerticalSlider.fill(for: -1, height: height).base == 0)
    }
}

/// Moving the input trim by hand while automatic levelling is running.
///
/// The loop works relative to a base captured when it was switched on, and sets
/// the trim to `base + offset` on every tick. Nothing updated that base when
/// somebody moved the trim themselves, so the next tick put it straight back —
/// and in a quiet room the offset is zero, so it went back to exactly where it
/// had been. The control did not work at all while the feature was on, and it
/// looked like a slider that springs.
@MainActor
@Suite("Moving the trim under automatic levelling")
struct AutoLevelRebaseTests {

    /// The invariant: whatever the user chose is what the next tick produces.
    @Test("the total does not move, whatever the loop had added")
    func totalIsPreserved() {
        for offset in [0.0, 3.5, -6.0, 12.0] {
            for trim in [0, -8, 4.5, 20] as [Float] {
                let base = RouterModel.autoLevelBase(afterManual: trim, offset: offset)
                // This is what `stepAutoLevel` computes on its next tick.
                #expect(abs(base + Float(offset) - trim) < 0.001, "\(trim) dB, \(offset) off")
            }
        }
    }

    /// With the loop having done nothing yet — a quiet room, which is the case
    /// that made this look like a slider that springs back — the base is simply
    /// what was chosen.
    @Test("with no offset the base is what was chosen")
    func quietRoom() {
        #expect(RouterModel.autoLevelBase(afterManual: -6, offset: 0) == -6)
    }
}

/// Which transports lose their output quality to carrying a microphone.
///
/// The oldest complaint about audio on this platform: put on a Bluetooth
/// headset, join a call, and the music becomes a telephone. It is not a macOS
/// bug and there is nothing to set — the macOS 27 SDK was searched for this.
/// CoreAudio publishes no profile or codec property, only a transport type; and
/// `AVAudioSessionCategoryOptionBluetoothHighQualityRecording`, which is exactly
/// the switch anybody would want, is marked `API_AVAILABLE(ios(26.0))` and
/// `API_UNAVAILABLE(macos)`.
///
/// Classic Bluetooth does one profile at a time: A2DP is output-only and good,
/// HFP carries both directions at 8 or 16 kHz mono. LE Audio's LC3 does not
/// have to choose, which is why the two are separate cases here — telling
/// somebody with LE Audio hardware that they have this problem would be wrong.
@Suite("Which transports pay for their own microphone")
struct BluetoothProfileTests {

    @Test("classic Bluetooth pays, LE Audio does not")
    func onlyClassicPays() {
        #expect(AudioTransport.bluetooth.losesOutputQualityToItsMicrophone)
        #expect(!AudioTransport.bluetoothLE.losesOutputQualityToItsMicrophone)
    }

    /// Nothing wired does, which is the whole reason the advice this drives is
    /// "take the microphone from somewhere else" rather than "buy a better
    /// headset".
    @Test("no wired transport pays")
    func wiredNeverPays() {
        let wired: [AudioTransport] = [
            .builtIn, .usb, .thunderbolt, .hdmi, .displayPort, .airPlay, .virtual,
            .aggregate, .pci, .fireWire, .avb, .unknown,
        ]
        for transport in wired {
            #expect(!transport.losesOutputQualityToItsMicrophone, "\(transport)")
        }
    }

    /// Both flavours are still Bluetooth for everything that only cares that it
    /// is wireless.
    @Test("both flavours read as Bluetooth")
    func bothAreBluetooth() {
        #expect(AudioTransport.bluetooth.isBluetooth)
        #expect(AudioTransport.bluetoothLE.isBluetooth)
        #expect(!AudioTransport.usb.isBluetooth)
        #expect(!AudioTransport.builtIn.isBluetooth)
    }

    /// The two are distinct values, which is the point of splitting them and
    /// the thing a careless `init` would undo.
    @Test("the two are not the same case")
    func notTheSameCase() {
        #expect(AudioTransport.bluetooth != AudioTransport.bluetoothLE)
    }
}

/// Which application has the microphone open.
///
/// The half of "what is using my audio" that macOS shows an orange dot for and
/// never names, and the answer to the oldest complaint on this platform: a
/// Bluetooth headset drops to telephone quality the moment anything opens its
/// microphone, and until now there was no way to find out what.
///
/// `kAudioProcessPropertyIsRunningInput` has been published since macOS 14.4
/// and nothing here asked. Measured to work before any of this was built: a
/// process opening an input was identified by PID exactly.
@Suite("Who has the microphone open")
struct RecordingApplicationTests {

    private func process(
        _ id: AudioObjectID, pid: pid_t, bundle: String?, name: String,
        playing: Bool = false, recording: Bool = false
    ) -> AudioApplications.ProcessEntry {
        AudioApplications.ProcessEntry(
            id: id, pid: pid, bundleID: bundle, name: name, isPlaying: playing,
            isRecording: recording)
    }

    /// The case that was dropped outright: something with no bundle holding the
    /// microphone and making no sound. Silent had been taken to mean "making no
    /// noise" rather than "using no audio", so the process was filtered away
    /// from the one list that exists to say what is using the audio.
    @Test("a recorder with no bundle is listed rather than dropped")
    func bundlelessRecorderSurvives() {
        let apps = AudioApplications.group(
            processes: [process(1, pid: 10, bundle: nil, name: "ffmpeg", recording: true)],
            foreground: [:],
            named: [:])
        #expect(apps.count == 1)
        #expect(apps.first?.isRecording == true)
        #expect(apps.first?.isPlaying == false)
    }

    /// And one that is neither playing nor recording is still dropped, because
    /// that long tail is what the filter is for.
    @Test("a process using no audio at all is still dropped")
    func idleProcessStillDropped() {
        let apps = AudioApplications.group(
            processes: [process(1, pid: 10, bundle: nil, name: "somedaemon")],
            foreground: [:],
            named: [:])
        #expect(apps.isEmpty)
    }

    /// Recording folds across helpers the same way playing does: a conferencing
    /// application holds the microphone in a helper process, and the row that
    /// has to say so is the application's.
    @Test("a helper holding the microphone marks its application")
    func recordingFoldsIntoTheApplication() {
        let apps = AudioApplications.group(
            processes: [
                process(1, pid: 10, bundle: "us.zoom.xos", name: "Zoom"),
                process(
                    2, pid: 11, bundle: "us.zoom.xos.helper", name: "Helper", recording: true),
            ],
            foreground: ["us.zoom.xos": .init(name: "Zoom")],
            named: ["us.zoom.xos": .init(name: "Zoom")])
        #expect(apps.count == 1)
        #expect(apps.first?.isRecording == true)
    }

    /// The two states are independent. A player that is not recording must not
    /// be reported as holding the microphone, or the warning this drives would
    /// name the wrong application — which is worse than naming none.
    @Test("playing is not recording")
    func playingIsNotRecording() {
        let apps = AudioApplications.group(
            processes: [
                process(
                    1, pid: 10, bundle: "com.spotify.client", name: "Spotify", playing: true)
            ],
            foreground: ["com.spotify.client": .init(name: "Spotify")],
            named: ["com.spotify.client": .init(name: "Spotify")])
        #expect(apps.first?.isPlaying == true)
        #expect(apps.first?.isRecording == false)
    }
}

/// The scripting interface.
///
/// Audio Hijack's JavaScript API is the feature every review of it singles out,
/// and the open goal is that Loopback has no scripting, no AppleScript and no
/// Shortcuts at all. JavaScriptCore ships with macOS, so the interpreter is
/// free and the work is entirely the object model — which is a promise about
/// compatibility, and a promise only ever checked by hand is not one.
///
/// Every case here runs real JavaScript through a real `JSContext` against a
/// stub, so what is asserted is what somebody's script will actually meet.
@MainActor
@Suite("The scripting interface")
struct ScriptingTests {

    /// Records what was asked for, so a script can be checked by what it did
    /// rather than by what it returned.
    final class Target: ScriptTarget {
        var performed: [RemoteCommand] = []
        var known: Set<String> = ["Voice chat"]
        var status: [String: Any] = ["running": false, "muted": false]

        func perform(_ command: RemoteCommand) -> String? {
            performed.append(command)
            switch command {
            case .preset(let name), .config(let name):
                // Nil is how the model says "no such thing", and the script
                // layer has to turn that into an error rather than a shrug.
                lastCommandFailed = !known.contains(name)
                return known.contains(name) ? "applied \(name)" : nil
            default:
                // Left alone rather than cleared: one set of cases sets it from
                // outside to stand for whatever happened before, and clearing
                // it here would make `perform` erase the thing under test.
                return "done"
            }
        }
        var scriptStatus: [String: Any] { status }
        var scriptPresetNames: [String] { ["Voice chat", "Recording"] }
        var scriptConfigNames: [String] { ["Streaming"] }
        /// Settable, because one set of cases drives it from outside and the
        /// other wants `perform` to set it — the same two ways the model is
        /// used. `perform` writes it for the case that has a rule: a command
        /// that named something this application does not have.
        var lastCommandFailed = false
    }

    private func host() -> (ScriptHost, Target) {
        let target = Target()
        return (ScriptHost(target: target), target)
    }

    @Test("a command reaches the application")
    func commandsArrive() {
        let (host, target) = self.host()
        let result = host.run("yun.routing(true); yun.mute(false);")
        #expect(result.isSuccess, "\(result.error ?? "")")
        #expect(target.performed == [.routing(true), .mute(false)])
    }

    /// The three states the URL scheme has, for the same reason: a button with
    /// no light has to be able to ask for a toggle.
    @Test("no argument means toggle")
    func absentArgumentToggles() {
        let (host, target) = self.host()
        _ = host.run("yun.mute(); yun.record(); yun.transcribe();")
        #expect(target.performed == [.mute(nil), .record(nil), .transcribe(nil)])
    }

    /// A scene renamed since somebody wrote the script must stop the script,
    /// not be skipped. Carrying on would leave the rest of it running against
    /// an arrangement nobody chose.
    @Test("a name the application does not have is an error, not a shrug")
    func unknownNameThrows() {
        let (host, target) = self.host()
        let result = host.run("yun.preset('Gone'); yun.routing(true);")
        #expect(!result.isSuccess)
        #expect(result.error?.contains("Gone") == true)
        // And nothing after it ran.
        #expect(target.performed == [.preset("Gone")])
    }

    @Test("a name it does have comes back with what happened")
    func knownNameSucceeds() {
        // The target is bound rather than discarded: the host holds it weakly,
        // so a test that lets it go is testing a host with nothing behind it.
        let (host, target) = self.host()
        _ = target
        let result = host.run("yun.preset('Voice chat')")
        #expect(result.isSuccess, "\(result.error ?? "")")
        #expect(result.value == "applied Voice chat")
    }

    @Test("state is readable, and readable as one moment")
    func statusIsReadable() {
        let (host, target) = self.host()
        target.status = ["running": true, "muted": false, "sampleRate": 48000]
        let result = host.run("var s = yun.status(); s.running && s.sampleRate === 48000")
        #expect(result.isSuccess, "\(result.error ?? "")")
        #expect(result.value == "true")
    }

    @Test("the lists say what names exist rather than leaving them to be guessed")
    func listsAreReadable() {
        let (host, target) = self.host()
        _ = target
        let result = host.run("yun.presets().join(',') + '|' + yun.configs().join(',')")
        #expect(result.value == "Voice chat,Recording|Streaming")
    }

    @Test("a script can say something, by either spelling")
    func loggingWorks() {
        let (host, target) = self.host()
        _ = target
        let result = host.run("yun.log('one'); console.log('two');")
        #expect(result.log == ["one", "two"])
    }

    /// Syntax errors are a message, not a crash. A script is untrusted text and
    /// the only correct answer to a bad one is a sentence.
    @Test("a broken script comes back with a message")
    func syntaxErrorIsReported() {
        let (host, target) = self.host()
        _ = target
        let result = host.run("this is not javascript {{{")
        #expect(!result.isSuccess)
        #expect(result.error?.isEmpty == false)
    }

    @Test("a script that throws comes back with its own message")
    func thrownErrorIsReported() {
        let (host, target) = self.host()
        _ = target
        let result = host.run("throw new Error('nope')")
        #expect(result.error?.contains("nope") == true)
    }

    /// The one that decides whether this feature can ship at all. The model
    /// lives on the main actor, so a script with an endless loop would take the
    /// interface with it — and nothing in JavaScriptCore's public Swift surface
    /// can interrupt a loop that makes no function calls. The time limit is
    /// declared by hand in YunAudioRT.h for exactly this, and this is the check
    /// that says it is still there: if a future macOS drops it, this fails here
    /// rather than hanging on somebody's machine.
    @Test("an endless loop is stopped rather than hanging the application")
    func runawayScriptIsStopped() {
        let (host, target) = self.host()
        _ = target
        let began = Date()
        let result = host.run("while (true) {}")
        let elapsed = Date().timeIntervalSince(began)
        #expect(!result.isSuccess, "an endless loop reported success")
        // Generously bounded: the limit is two seconds and the check is that it
        // returns at all, not that it returns punctually.
        #expect(elapsed < 20, "took \(elapsed)s")
    }

    /// What a script cannot do is as much of the design as what it can. The
    /// context starts empty — there is nothing to escape from rather than a
    /// sandbox somebody has to maintain — and this says so in the four ways
    /// anybody would try.
    @Test("there is no filesystem, no network, no timers and no require")
    func nothingElseIsReachable() {
        let (host, target) = self.host()
        _ = target
        for global in ["require", "fetch", "XMLHttpRequest", "setTimeout", "process"] {
            let result = host.run("typeof \(global)")
            #expect(result.value == "undefined", "\(global) is reachable")
        }
    }

    /// A run leaves nothing behind for the next one, or one script could set a
    /// global that changes what the next one means.
    @Test("one run cannot reach into the next")
    func runsAreIsolated() {
        let (host, target) = self.host()
        _ = target
        _ = host.run("var leftBehind = 42")
        let result = host.run("typeof leftBehind")
        #expect(result.value == "undefined")
    }
}

/// A script as a URL, which is how anything outside this application sends one.
///
/// The round trip is the compatibility promise: somebody wires a Stream Deck
/// key to a URL once, and it has to still mean the same script a year later.
@Suite("Sending a script from outside")
struct ScriptURLTests {

    @Test("a script survives the round trip through a URL")
    func roundTrip() throws {
        let sources = [
            "yun.mute(true)",
            "yun.preset('Voice chat'); yun.routing(true)",
            "var s = yun.status(); yun.log(s.running ? 'on' : 'off')",
            // The characters a URL would otherwise read as structure.
            "yun.log('a?b#c&d=e')",
            "if (yun.status().peak > 0.5) { yun.mute(true); }",
        ]
        for source in sources {
            let url = try #require(URL(string: RemoteCommand.script(source).url.absoluteString))
            #expect(RemoteCommand.parse(url) == .script(source), "\(source)")
        }
    }

    /// An empty script is not a command. Answering "ran nothing successfully"
    /// to a malformed URL is how a typo becomes a silent no-op.
    @Test("an empty script is not a command")
    func emptyIsRejected() {
        #expect(RemoteCommand.parse(URL(string: "yunaudio://script/")!) == nil)
        #expect(RemoteCommand.parse(URL(string: "yunaudio://script")!) == nil)
    }

    @Test("both spellings of the noun are accepted")
    func bothNouns() {
        let one = RemoteCommand.parse(URL(string: "yunaudio://script/yun.mute()")!)
        let other = RemoteCommand.parse(URL(string: "yunaudio://run/yun.mute()")!)
        #expect(one == .script("yun.mute()"))
        #expect(other == .script("yun.mute()"))
    }
}

/// Scripts that stay and react.
///
/// A scripting interface with no triggers is half an interface — automation is
/// what Audio Hijack's is praised for, and a script that can only be run by
/// hand is a slower way of pressing a button. These run real JavaScript in a
/// real resident context and then make the events happen.
@MainActor
@Suite("Scripts that react to things")
struct ScriptEventTests {

    private func host() -> (ScriptHost, ScriptingTests.Target) {
        let target = ScriptingTests.Target()
        return (ScriptHost(target: target), target)
    }

    @Test("a handler is called when the thing happens")
    func handlerFires() {
        let (host, target) = self.host()
        _ = target
        let loaded = host.load("yun.on('start', function () { yun.log('up'); });")
        #expect(loaded.isSuccess, "\(loaded.error ?? "")")
        let fired = host.dispatch(.routingStarted)
        #expect(fired.log == ["up"])
    }

    /// The payload is how an event says anything useful. Without it a handler
    /// has to go and ask, and by then the moment has moved.
    @Test("a handler is given what happened")
    func handlerReceivesPayload() {
        let (host, target) = self.host()
        _ = target
        _ = host.load("yun.on('tick', function (e) { yun.log('peak ' + e.peak); });")
        let fired = host.dispatch(.tick, ["peak": 0.25])
        #expect(fired.log == ["peak 0.25"])
    }

    /// Several scripts watching one event is the ordinary case: one watching
    /// the microphone and another watching the recording are not one script.
    @Test("every handler for an event is called")
    func allHandlersFire() {
        let (host, target) = self.host()
        _ = target
        _ = host.load(
            """
            yun.on('muted', function () { yun.log('one'); });
            yun.on('muted', function () { yun.log('two'); });
            """)
        #expect(host.dispatch(.muted).log == ["one", "two"])
    }

    /// A typo in an event name would otherwise be a script that looks right,
    /// loads cleanly and does nothing for ever — the worst outcome available.
    @Test("an event name that does not exist is an error at load time")
    func unknownEventIsRejected() {
        let (host, target) = self.host()
        _ = target
        let loaded = host.load("yun.on('started', function () {});")
        #expect(!loaded.isSuccess)
        #expect(loaded.error?.contains("started") == true)
        // And the list of real names is in the message, because the next thing
        // anybody wants to know is what they should have typed.
        #expect(loaded.error?.contains("start") == true)
    }

    /// A handler that throws must not take the others with it, and must not
    /// quietly unregister itself: an event that failed once because a device
    /// was busy should still be handled for the rest of the session.
    @Test("a handler that throws does not stop the others or itself")
    func oneBadHandlerDoesNotStopTheRest() {
        let (host, target) = self.host()
        _ = target
        _ = host.load(
            """
            yun.on('stop', function () { throw new Error('bad'); });
            yun.on('stop', function () { yun.log('still here'); });
            """)
        let first = host.dispatch(.routingStopped)
        #expect(first.log == ["still here"])
        #expect(first.error?.contains("bad") == true)
        // Again, and it is still registered.
        #expect(host.dispatch(.routingStopped).log == ["still here"])
    }

    /// A resident script keeps its own state — that is the whole reason the
    /// context is kept rather than rebuilt for each event.
    @Test("a script remembers between events")
    func stateSurvivesBetweenEvents() {
        let (host, target) = self.host()
        _ = target
        _ = host.load(
            "var seen = 0; yun.on('tick', function () { seen++; yun.log('' + seen); });")
        _ = host.dispatch(.tick)
        _ = host.dispatch(.tick)
        #expect(host.dispatch(.tick).log == ["3"])
    }

    /// Loading replaces. Two copies of a script both reacting is not what
    /// anybody means by editing one.
    @Test("loading again replaces what was there")
    func loadingReplaces() {
        let (host, target) = self.host()
        _ = target
        _ = host.load("yun.on('muted', function () { yun.log('old'); });")
        _ = host.load("yun.on('muted', function () { yun.log('new'); });")
        #expect(host.dispatch(.muted).log == ["new"])
    }

    /// A script that fails while loading leaves nothing behind. Half a script
    /// reacting to things is worse than none, because the half that is there
    /// looks like the whole.
    @Test("a script that throws while loading registers nothing")
    func failedLoadRegistersNothing() {
        let (host, target) = self.host()
        _ = target
        let loaded = host.load(
            "yun.on('muted', function () { yun.log('half'); }); throw new Error('nope');")
        #expect(!loaded.isSuccess)
        #expect(host.dispatch(.muted).log.isEmpty)
        #expect(!host.listens(for: .muted))
    }

    /// The same limit as a one-shot run, and for a stronger reason: a handler
    /// runs on somebody else's schedule rather than on a person pressing a
    /// button, so an endless loop in one would hang the application at a moment
    /// nobody chose.
    @Test("an endless loop inside a handler is stopped too")
    func runawayHandlerIsStopped() {
        let (host, target) = self.host()
        _ = target
        _ = host.load("yun.on('tick', function () { while (true) {} });")
        let began = Date()
        let fired = host.dispatch(.tick)
        #expect(!fired.isSuccess, "an endless handler reported success")
        #expect(Date().timeIntervalSince(began) < 20)
    }

    /// Dispatching something nothing listens for costs nothing and says
    /// nothing, because most events have no handler most of the time.
    @Test("an event nobody listens for is quiet")
    func unhandledEventIsQuiet() {
        let (host, target) = self.host()
        _ = target
        _ = host.load("yun.on('start', function () { yun.log('up'); });")
        let fired = host.dispatch(.deviceAppeared)
        #expect(fired.log.isEmpty)
        #expect(fired.isSuccess)
        #expect(!host.listens(for: .deviceAppeared))
        #expect(host.listens(for: .routingStarted))
    }

    /// A handler can act, not only observe — otherwise this is a logging
    /// facility rather than automation.
    @Test("a handler can drive the application")
    func handlerCanAct() {
        let (host, target) = self.host()
        _ = host.load("yun.on('speakingWhileMuted', function () { yun.mute(false); });")
        _ = host.dispatch(.speakingWhileMuted)
        #expect(target.performed == [.mute(false)])
    }
}

/// Where a wrapping row breaks.
///
/// Greedy packing is right for a row of pills that happens to be long: it fills
/// each line and the ragged end is nobody's business. It is wrong for a tab
/// bar. Six tabs across a column that fits five leaves one alone on a second
/// line, which reads as a mistake rather than as a row that wrapped — and that
/// is exactly what adding a sixth tab produced, found by photographing the real
/// window at its minimum size.
@Suite("Where a wrapping row breaks")
struct WrapBreakTests {

    /// Pills of equal width, which is what a row of two-character tabs is.
    private func even(_ count: Int, _ width: CGFloat = 48) -> [CGFloat] {
        [CGFloat](repeating: width, count: count)
    }

    @Test("one line stays one line")
    func noWrapNeeded() {
        let lines = YunWrap.breaks(
            widths: even(4), within: 400, spacing: 6, balanced: true)
        #expect(lines.count == 1)
        #expect(lines[0].count == 4)
    }

    /// The case this exists for: six where five fit.
    @Test("six across a row that fits five goes three and three")
    func sixGoesThreeAndThree() {
        let width: CGFloat = 5 * 48 + 4 * 6
        let lines = YunWrap.breaks(
            widths: even(6), within: width, spacing: 6, balanced: true)
        #expect(lines.count == 2)
        #expect(lines.map(\.count) == [3, 3])
    }

    /// Greedy leaves the orphan, which is what was on screen. Kept as a case so
    /// the difference between the two is stated rather than assumed.
    @Test("greedy leaves the orphan that balancing removes")
    func greedyOrphans() {
        let width: CGFloat = 5 * 48 + 4 * 6
        let lines = YunWrap.breaks(
            widths: even(6), within: width, spacing: 6, balanced: false)
        #expect(lines.map(\.count) == [5, 1])
    }

    /// Balancing must never cost a line. The point is the shape of the wrap,
    /// not more wrapping — a tab bar that grew a third row to look tidy would
    /// be a worse trade than the orphan.
    @Test("balancing never uses more lines than greedy")
    func neverCostsALine() {
        for count in 1...12 {
            for fits in 1...6 {
                let width = CGFloat(fits) * 48 + CGFloat(fits - 1) * 6
                let widths = even(count)
                let greedy = YunWrap.breaks(
                    widths: widths, within: width, spacing: 6, balanced: false)
                let balanced = YunWrap.breaks(
                    widths: widths, within: width, spacing: 6, balanced: true)
                #expect(balanced.count <= greedy.count, "\(count) items, \(fits) per line")
                // And nothing is lost or duplicated on the way.
                #expect(balanced.flatMap { $0 } == Array(0..<count))
            }
        }
    }

    /// Uneven widths still have to fit. Balancing counts items, so a line of
    /// wide ones could overflow if the count were the only rule — it is not.
    @Test("a wide item still breaks the line it does not fit on")
    func wideItemsStillFit() {
        let widths: [CGFloat] = [200, 40, 40, 200, 40, 40]
        let lines = YunWrap.breaks(widths: widths, within: 300, spacing: 6, balanced: true)
        for line in lines {
            let used =
                line.map { widths[$0] }.reduce(0, +) + 6 * CGFloat(max(0, line.count - 1))
            #expect(used <= 300, "a line came to \(used)")
        }
        #expect(lines.flatMap { $0 } == Array(0..<widths.count))
    }
}

/// The command line as a front end onto the same verbs.
///
/// Argument handling is exactly the kind of code that is written once, reads
/// obviously right, and turns `mute off` into a toggle for a year. It is a pure
/// function over an array of strings so that it can be asserted rather than
/// tried, and there is a case per verb because a verb nobody wrote a case for
/// is a verb nobody checked.
@Suite("The command line")
struct ControlArgumentsTests {

    @Test("every verb reaches the command the URL scheme would")
    func verbs() {
        let expected: [([String], ControlArguments.Outcome)] = [
            (["start"], .perform(.routing(true))),
            (["stop"], .perform(.routing(false))),
            (["toggle"], .perform(.routing(nil))),
            (["routing", "on"], .perform(.routing(true))),
            (["mute"], .perform(.mute(nil))),
            (["mute", "on"], .perform(.mute(true))),
            (["mute", "off"], .perform(.mute(false))),
            (["record", "on"], .perform(.record(true))),
            (["transcribe", "off"], .perform(.transcribe(false))),
            (["preset", "Voice call"], .perform(.preset("Voice call"))),
            (["config", "Podcast"], .perform(.config("Podcast"))),
            (["script", "yun.mute()"], .perform(.script("yun.mute()"))),
            (["status"], .status),
        ]
        for (arguments, outcome) in expected {
            #expect(ControlArguments.parse(arguments) == outcome, "\(arguments)")
        }
    }

    /// Somebody typing into a terminal has the caps lock in whatever state they
    /// left it, and refusing over that is pedantry rather than safety.
    @Test("case does not matter")
    func caseInsensitive() {
        #expect(ControlArguments.parse(["MUTE", "ON"]) == .perform(.mute(true)))
        #expect(ControlArguments.parse(["Stop"]) == .perform(.routing(false)))
        // The name, though, is the user's own text and is passed through as
        // typed. Matching it without case is the model's job, and it does it.
        #expect(ControlArguments.parse(["preset", "VOICE"]) == .perform(.preset("VOICE")))
    }

    /// The words the URL scheme accepts, accepted here too. One definition of
    /// what "on" means, not two.
    @Test("the URL scheme's words for on and off all work")
    func statesMatchTheURLScheme() {
        for word in ["on", "start", "1", "true", "yes"] {
            #expect(ControlArguments.parse(["mute", word]) == .perform(.mute(true)), "\(word)")
        }
        for word in ["off", "stop", "0", "false", "no"] {
            let parsed = ControlArguments.parse(["mute", word])
            #expect(parsed == .perform(.mute(false)), "\(word)")
        }
    }

    /// A name with spaces in it should not need quoting, because the scenes
    /// this application ships with have spaces in their names.
    @Test("a name is joined rather than truncated")
    func namesJoin() {
        #expect(
            ControlArguments.parse(["preset", "Voice", "call"])
                == .perform(.preset("Voice call")))
    }

    /// Nothing outside the control vocabulary may be claimed: the measuring
    /// half of the tool is behind these and a verb swallowed here is a verb
    /// that stopped working.
    @Test("the measuring verbs are left alone")
    func harnessVerbsAreNotClaimed() {
        for verb in [
            "selftest", "soak", "dsp", "route", "capture", "tone", "light", "apps",
            "tap", "volume", "aec", "bench", "mic", "vad", "swap", "timing",
        ] {
            #expect(ControlArguments.parse([verb]) == .notMine, "\(verb)")
        }
        #expect(ControlArguments.parse([]) == .notMine)
        // Named apart because the URL scheme *does* accept `route` for
        // routing, and taking it here would have quietly broken the measuring
        // verb of the same name.
        #expect(
            ControlArguments.parse(["route", "Mic", "YunAudio", "5"]) == .notMine)
    }

    /// A word that is not on, off or toggle is refused rather than guessed at.
    /// The failure being avoided is a mistyped mute that turns into a stop.
    @Test("an unrecognised state is refused, with the alternatives named")
    func badStateIsRefused() {
        guard case .complaint(let message) = ControlArguments.parse(["mute", "sometimes"])
        else {
            Issue.record("a nonsense state was accepted")
            return
        }
        #expect(message.contains("sometimes"))
        #expect(message.contains("on, off or toggle"))
    }

    /// `record` was the harness verb that captured seconds to a file, so
    /// `record 5` is a line somebody's notes still have in them. It has to say
    /// where that went rather than just refusing.
    @Test("the old meaning of record is named in its own error")
    func recordCollisionIsExplained() {
        guard case .complaint(let message) = ControlArguments.parse(["record", "5"]) else {
            Issue.record("record 5 was taken as a state")
            return
        }
        #expect(message.contains("capture 5"))
    }

    /// `stop recording` reads like an instruction and means "stop routing".
    /// Dropping the extra word would do something nobody asked for.
    @Test("a verb that takes nothing refuses an argument")
    func extraArgumentsAreRefused() {
        guard case .complaint = ControlArguments.parse(["stop", "recording"]) else {
            Issue.record("an extra word was silently dropped")
            return
        }
        guard case .complaint = ControlArguments.parse(["status", "now"]) else {
            Issue.record("status took an argument")
            return
        }
    }

    @Test("a name is required where one is meant")
    func missingNamesAreRefused() {
        for verb in ["preset", "config", "script"] {
            guard case .complaint = ControlArguments.parse([verb]) else {
                Issue.record("\(verb) accepted no name")
                return
            }
        }
    }

    /// The line the tool prints for `--url` has to be a line the application
    /// actually answers to, or it is a copy-paste that silently does nothing.
    @Test("everything the command line can produce survives the URL scheme")
    func everythingRoundTrips() {
        let lines = [
            ["start"], ["stop"], ["toggle"], ["mute"], ["mute", "off"], ["record", "on"],
            ["transcribe"], ["preset", "Voice call"], ["config", "Podcast"],
            ["script", "yun.log('a?b#c'); yun.mute(true)"],
        ]
        for line in lines {
            guard case .perform(let command) = ControlArguments.parse(line) else {
                Issue.record("\(line) did not parse")
                return
            }
            #expect(RemoteCommand.parse(command.url) == command, "\(line)")
        }
    }
}

/// What the application says back to another process.
///
/// There is one transport now: the control socket, which `yunaudio-cli` and
/// `yunaudio-mcp` both speak. `yunaudio-cli` used to have a
/// distributed-notification channel of its own, and this suite is what that
/// channel's tests became — every case below asserts something that was true of
/// the notification reply and had to stay true of the socket one, because a
/// carry-across that is only checked by reading it is not a carry-across.
///
/// Written against `ScriptTarget` and a stub, for the reason the scripting
/// layer is: a reply that misreports the state is exactly the defect that looks
/// fine from outside.
@MainActor
@Suite("Answering another process")
struct ControlAnswerTests {

    /// The one that will bite. A `Bool` inside `Any` bridges to `NSNumber`, and
    /// so does an `Int`: ordinary `as? Bool` casting turns "one route" into
    /// "routes: yes", and `as? Int` turns a level of −70.0 dB into "-70" while
    /// −69.5 stays a decimal. Both were observed in the first status printed.
    @Test("a count is not a flag, and a whole number is not a count")
    func numbersKeepTheirType() {
        #expect(JSONValue(any: 1) == .int(1))
        #expect(JSONValue(any: 0) == .int(0))
        #expect(JSONValue(any: true) == .bool(true))
        #expect(JSONValue(any: false) == .bool(false))
        #expect(JSONValue(any: 1.5) == .double(1.5))
        #expect(JSONValue(any: -70.0) == .double(-70))
        #expect(JSONValue(any: 0.0) == .double(0))
        #expect(JSONValue(any: "gate") == .string("gate"))
        #expect(
            JSONValue(any: ["gate", "limiter"])
                == .array([.string("gate"), .string("limiter")]))
        #expect(JSONValue(any: Data()) == nil)

        // And how each of them reads on a terminal, which is the half a type
        // alone does not fix.
        #expect(JSONValue(any: 0.0)?.described == "0.00")
        #expect(JSONValue(any: 0)?.described == "0")
        #expect(JSONValue(any: true)?.described == "yes")
        #expect(JSONValue(any: false)?.described == "no")
        #expect(JSONValue(any: ["gate", "limiter"])?.described == "gate limiter")
        #expect(JSONValue(any: [String]())?.described == "—")
        // A level of −∞ dBFS is what a meter reads with nothing plugged in, and
        // JSON has no word for it. One dash, not a document that failed.
        #expect(JSONValue(any: -Double.infinity)?.described == "—")
    }

    /// The trap that made the channel this replaced tag every value on the wire:
    /// a level of exactly 0 dB written as a bare JSON number is `0`, which reads
    /// back as an integer, so the terminal printed "0" beside "-69.50".
    ///
    /// This encoding needs no tag because it never writes `0` for a double —
    /// `Double.description` is "0.0" and `JSONSerialization` reads that back as
    /// a floating-point `NSNumber`. That is a property of two pieces of
    /// Foundation behaviour rather than of anything written down here, which is
    /// exactly why it is asserted rather than assumed.
    @Test("a status survives the wire with every value still the type it was")
    func statusRoundTripsThroughItsOwnText() throws {
        let status = JSONValue.object([
            "running": .bool(true), "routes": .int(2), "peak": .double(0.5),
            "loudness": .double(0), "bufferFrames": .int(0), "muted": .bool(false),
            "source": .string("Mic"), "effects": .array([]),
        ])
        let reply = ControlReply.status(status)
        let onTheWire = try #require(JSONValue.parse(reply.json.text))
        let back = try #require(ControlReply(json: onTheWire))
        #expect(back == reply)

        guard case .status(let read) = back else {
            Issue.record("the status came back as \(back)")
            return
        }
        #expect(read["loudness"] == .double(0))
        #expect(read["loudness"]?.described == "0.00")
        #expect(read["bufferFrames"] == .int(0))
        #expect(read["bufferFrames"]?.described == "0")
        #expect(read["running"]?.described == "yes")
    }

    /// "No such scene" is a dead end. The names that would have worked travel
    /// with the refusal, so the tool can print them without asking again.
    @Test("a refusal carries the names that would have worked, across the wire")
    func refusalCarriesTheAlternatives() throws {
        let target = ScriptingTests.Target()
        let reply = ControlServer.answer(.perform(.preset("Voise chat")), model: target)
        #expect(
            reply
                == .failure(
                    "There is no scene called \"Voise chat\".",
                    alternatives: ["Voice chat", "Recording"]))

        let setup = ControlServer.answer(.perform(.config("Nope")), model: target)
        #expect(
            setup
                == .failure(
                    "There is no setup called \"Nope\".", alternatives: ["Streaming"]))

        // And the list is still there on the far side. An `alternatives` key
        // that only exists in the struct is a list nothing ever prints.
        let onTheWire = try #require(JSONValue.parse(reply.json.text))
        #expect(try #require(ControlReply(json: onTheWire)) == reply)
    }

    /// A sentence is not an exit status.
    ///
    /// A script that throws still produces a sentence — the interpreter's
    /// error — so a shell reading only the text could not tell a script that had
    /// stopped working from one that was working. `yunaudio-cli script` printed
    /// the error and exited 0 for exactly as long as nothing asserted this.
    @Test("a command that failed says so, separately from what it printed")
    func failureIsCarriedApartFromTheSentence() {
        let target = ScriptingTests.Target()
        target.lastCommandFailed = true
        #expect(
            ControlServer.answer(.perform(.mute(true)), model: target)
                == .failure("done"))

        // A question cannot fail, and must not report a failure left over from
        // whatever the last command was.
        guard case .status = ControlServer.answer(.status, model: target) else {
            Issue.record("a question reported the last command's failure")
            return
        }

        // And a command that worked is a message, not a failure — otherwise the
        // case above passes for the wrong reason.
        target.lastCommandFailed = false
        #expect(
            ControlServer.answer(.perform(.mute(true)), model: target) == .message("done"))
    }

    @Test("a command reaches the application and its sentence comes back")
    func commandsArePerformed() {
        let target = ScriptingTests.Target()
        #expect(
            ControlServer.answer(.perform(.mute(true)), model: target) == .message("done"))
        #expect(target.performed == [.mute(true)])
    }

    /// The whole point of keeping `status` out of `RemoteCommand`: asking what
    /// is happening must not change what is happening.
    @Test("asking changes nothing")
    func statusPerformsNothing() {
        let target = ScriptingTests.Target()
        target.status = ["running": true, "routes": 3]
        let reply = ControlServer.answer(.status, model: target)
        #expect(target.performed.isEmpty)
        #expect(reply == .status(.object(["running": .bool(true), "routes": .int(3)])))
    }

    @Test("the names come back as the two lists that exist")
    func namesAreListed() {
        let target = ScriptingTests.Target()
        #expect(
            ControlServer.answer(.names, model: target)
                == .names(scenes: ["Voice chat", "Recording"], setups: ["Streaming"]))
        #expect(target.performed.isEmpty)
    }
}

/// Failures the engine writes down, and what the interface says about them.
///
/// None of these can be produced on demand — an Audio Unit that will not
/// instantiate, a disk that fills — so the mapping is the only testable part.
/// It is worth testing because the alternative to a wrong sentence here is what
/// was there before, which was no sentence at all.
@MainActor
@Suite("Saying why something did not come up")
struct FailureMessageTests {

    /// Matched against the engine's own constants, so a reworded phrase is a
    /// compile-time change rather than a silent fall-through to raw English.
    @Test("every isolation failure the engine can record has a sentence")
    func isolationFailuresAreExplained() {
        for reason in [
            RoutingEngine.IsolationFailure.chainNotBuilt,
            RoutingEngine.IsolationFailure.unitNotInstantiated,
        ] {
            let message = RouterModel.isolationMessage(reason)
            #expect(message != reason, "\(reason)")
            #expect(message.contains(loc("Voice isolation is not running: %@.").prefix(5)))
        }
    }

    /// A reason from a version that has since gained one is shown rather than
    /// swallowed. Somebody reading the engine's own words is worse than a
    /// translation and far better than silence.
    @Test("an unknown reason is passed through rather than dropped")
    func unknownIsolationReasonSurvives() {
        #expect(RouterModel.isolationMessage("something new").contains("something new"))
        #expect(RouterModel.echoMessage("something new") == "something new")
    }

    @Test("every echo cancellation failure the engine can record has a sentence")
    func echoFailuresAreExplained() {
        for reason in [
            RoutingEngine.EchoFailure.notBuilt, RoutingEngine.EchoFailure.wouldNotStart,
        ] {
            #expect(RouterModel.echoMessage(reason) != reason, "\(reason)")
        }
    }

    /// The field that had a picker, an engine reading it and a preset carrying
    /// it, and no line in the preferences file.
    @Test("the recording format has somewhere to be written down")
    func recordingFormatIsPersistable() throws {
        var preferences = Preferences.default
        #expect(preferences.recordingFormat == Recorder.Format.wav.rawValue)
        preferences.recordingFormat = Recorder.Format.aac.rawValue
        let data = try JSONEncoder().encode(preferences)
        let back = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(back.recordingFormat == Recorder.Format.aac.rawValue)
    }
}


/// Every public reader of the realtime graph takes the lock before it does.
///
/// This is a source check rather than a runtime one, because the failure it
/// guards against is a use-after-free: the engine queue frees the graph on every
/// stop and every rebuild, and a reader that arrives in between dereferences
/// memory that has gone. Two segfaults in one afternoon, one in `routePeaks` on
/// the main thread and one in the IO thread's ring write, with crash reports.
///
/// A test cannot reliably provoke that race — it is a few microseconds wide and
/// a run that does not hit it proves nothing. What can be checked is that no
/// accessor touches the graph without the lock, and that is exactly the mistake
/// that is easy to make again: the natural way to add a meter is a one-line
/// computed property, and the one-line version is the unsafe one.
///
/// Non-blocking is deliberate and is not the subject of this check.
/// `startAttempt` holds the lock across a synchronous message to `coreaudiod`,
/// so an interface reader that blocks freezes for as long as the audio server
/// takes — measured, with the whole main thread parked under one of these
/// getters. `stateLock.try()` counts as taking it.
@Suite("Every reader of the graph takes the lock")
struct GraphLockDisciplineTests {

    @Test("no public accessor touches the graph without the lock")
    func everyAccessorLocks() throws {
        let source = try String(
            contentsOfFile: Self.enginePath, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        var offenders: [String] = []
        for (index, line) in lines.enumerated() {
            guard line.contains("public var ") || line.contains("public func ") else {
                continue
            }
            // The declaration and its body, to the next public member.
            var body = ""
            for following in lines[index..<min(index + 18, lines.count)] {
                if following != line, following.contains("    public ") { break }
                body += following + "\n"
            }
            let touchesGraph =
                body.contains("graph?.pointee") || body.contains("graph.pointee")
                || body.contains("graphCell") || body.contains("isolationFailureCounter")
            if touchesGraph, !body.contains("stateLock") {
                offenders.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// The file has to be found, or the check above passes by reading nothing —
    /// which is the failure mode of every test that greps a file.
    @Test("and the source it reads is really there")
    func theSourceIsFound() throws {
        let source = try String(contentsOfFile: Self.enginePath, encoding: .utf8)
        #expect(source.contains("public var routePeaks"))
        #expect(source.count > 50_000)
    }

    /// Walks up from this file to the package root, so it does not depend on
    /// where the tests are run from.
    static var enginePath: String {
        var directory = URL(fileURLWithPath: #filePath)
        while directory.pathComponents.count > 1 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent(
                "Sources/YunAudioEngine/RoutingEngine.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return ""
    }
}

/// The way back out of installing a driver.
///
/// `DriverInstaller.uninstall()` existed and nothing called it. The application
/// offered to install a driver into `/Library` and gave no way at all to remove
/// one — the command was in the README and nowhere in the interface, which
/// makes it a change to somebody's machine that they have to go and look up how
/// to reverse. That is worse than an installation that fails.
///
/// What can be asserted without a driver actually installed is the shape of the
/// thing: that both directions exist, that they are each other's opposite, and
/// that the command really names the path it claims to.
@MainActor
@Suite("Taking the driver back off")
struct DriverRemovalTests {

    @Test("both directions exist and are opposites")
    func bothDirectionsExist() {
        // A change to `installPath` that reached one and not the other would
        // leave a driver nothing could remove, which is exactly the state this
        // is here to prevent.
        #expect(DriverInstaller.installPath.hasSuffix(".driver"))
        #expect(DriverInstaller.installPath.hasPrefix("/Library/Audio/Plug-Ins/HAL/"))
    }

    /// The interface reaches it. Asserted as source rather than by driving a
    /// window, because a button that calls nothing compiles perfectly.
    @Test("the interface has a way to reach it")
    func theInterfaceReachesIt() throws {
        let root = GraphLockDisciplineTests.enginePath
            .replacingOccurrences(of: "Sources/YunAudioEngine/RoutingEngine.swift", with: "")
        let preferences = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PreferencesWindow.swift",
            encoding: .utf8)
        #expect(preferences.contains("model.removeDriver()"))
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        #expect(model.contains("DriverInstaller.uninstall()"))
        // And it stops routing first: removing the plug-in restarts coreaudiod,
        // and a route running through the device that is about to stop existing
        // is an aggregate whose member vanishes underneath it.
        let removal = model.components(separatedBy: "func removeDriver()")
        try #require(removal.count == 2)
        let body = String(removal[1].prefix(400))
        #expect(body.contains("if isRunning { stop() }"))
    }
}

/// The fade at the bottom of a scrolling column.
///
/// It says "this carries on past here", and macOS gives no other sign — the
/// system scrollers are hidden until something touches them. So the fade is the
/// whole cue, and the depth of it is the whole design.
///
/// It used to be a *fraction* of the height: the mask's last six per cent. That
/// is a different depth at every window size, and at the sizes people actually
/// work at it stopped reading as a fade and started reading as content that had
/// been rubbed out. Nothing caught it, and nothing could: `MainWindow` takes an
/// `isRendering` branch that skips the scroll view entirely, so the offscreen
/// design check never builds the mask, and the window photographs are looked at
/// rather than measured.
///
/// This measures it. Two heights, one number.
@MainActor
@Suite("The scroll fade")
struct ScrollFadeTests {

    /// Renders a solid block through the real modifier and returns, for each
    /// row from the bottom, how opaque the block still is there.
    private func alphaUpFromTheBottom(height: CGFloat) throws -> [Double] {
        let width: CGFloat = 40
        let renderer = ImageRenderer(
            content: Rectangle()
                .fill(Color.black)
                .frame(width: width, height: height)
                .yunScrollFade())
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        // Row 0 is the bottom of the picture; bitmaps count from the top.
        return (0..<rep.pixelsHigh).reversed().map { row in
            Double(rep.colorAt(x: rep.pixelsWide / 2, y: row)?.alphaComponent ?? 0)
        }
    }

    /// How many points from the bottom the block is fully opaque again.
    private func fadeDepth(height: CGFloat) throws -> Int {
        let column = try alphaUpFromTheBottom(height: height)
        // The first row, counting up, that is essentially solid.
        return column.firstIndex { $0 > 0.99 } ?? column.count
    }

    @Test("it is the same depth whatever the column's height")
    func depthDoesNotFollowTheHeight() throws {
        // The window's minimum content height and a full-screen one, which is
        // the range somebody actually resizes through.
        let short = try fadeDepth(height: 440)
        let tall = try fadeDepth(height: 820)
        #expect(
            abs(short - tall) <= 2,
            "the fade is \(short) points on a short column and \(tall) on a tall one")
        // And it is the depth it says it is. A fraction-based mask would have
        // measured about 26 here and about 49 there — the numbers this replaced.
        #expect(abs(Double(short) - YunScrollFade.depth) <= 2, "short column: \(short)")
        #expect(abs(Double(tall) - YunScrollFade.depth) <= 2, "tall column: \(tall)")
    }

    /// A cue that covers a row is not a cue. The rows in this application start
    /// at 28 points, so a fade deeper than that would hide one outright rather
    /// than hint that it is there.
    @Test("and it never swallows a whole row")
    func doesNotCoverARow() {
        #expect(YunScrollFade.depth < 28)
        #expect(YunScrollFade.depth > 8, "a fade this shallow reads as a clipping bug")
    }

    @Test("the bottom edge really does reach transparent")
    func theBottomIsClear() throws {
        let column = try alphaUpFromTheBottom(height: 440)
        let bottom = try #require(column.first)
        let top = try #require(column.last)
        #expect(bottom < 0.05)
        #expect(top > 0.99)
    }
}

/// Whose channel names appear on which row.
///
/// The patchbay draws a row per source and labelled every one of them with the
/// *selected* device's channel names. With a Seiren V3 Pro chosen, a second
/// microphone's channels — and the channels of any captured application — came
/// out as "Processed", "Dry" and "Post-expander": names belonging to a device
/// the row has nothing to do with, on a control whose entire job is saying
/// which signal is which.
///
/// The rule is asserted here without a live HAL, because what went wrong is the
/// lookup key rather than the lookup.
@Suite("Whose channel names these are")
struct ChannelNameOwnershipTests {

    @Test("a device with a known topology gets its own names")
    func knownDeviceIsNamed() {
        let names = DeviceChannelNames.channels(
            modelUID: nil, name: "Razer Seiren V3 Pro",
            scope: kAudioObjectPropertyScopeInput)
        let channels = try? #require(names)
        #expect(channels?.count == 3)
        // Three taps of one capsule, which is the whole reason these are named.
        #expect(channels?.contains { $0.isDefault } == true)
    }

    /// The case that was wrong. Nothing about one device may describe another.
    @Test("a device with no profile gets no names, whatever else is selected")
    func unknownDeviceIsNotNamed() {
        for other in ["BlackHole 16ch", "MacBook Pro Microphone", "Some Interface"] {
            #expect(
                DeviceChannelNames.channels(
                    modelUID: nil, name: other, scope: kAudioObjectPropertyScopeInput)
                    == nil, "\(other)")
        }
    }

    /// And a profile only ever describes inputs. An output row asking for these
    /// would get the microphone's capsule names on a pair of speakers.
    @Test("output channels are never named from an input profile")
    func outputsAreNeverNamed() {
        #expect(
            DeviceChannelNames.channels(
                modelUID: nil, name: "Razer Seiren V3 Pro",
                scope: kAudioObjectPropertyScopeOutput) == nil)
    }

    /// The patchbay asks by device, not by whatever is selected. Asserted as
    /// source, because a label bound to the wrong property compiles perfectly.
    @Test("the patchbay labels each row from that row's own device")
    func patchbayAsksByDevice() throws {
        let root = GraphLockDisciplineTests.enginePath
            .replacingOccurrences(of: "Sources/YunAudioEngine/RoutingEngine.swift", with: "")
        let canvas = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RoutingCanvas.swift", encoding: .utf8)
        #expect(canvas.contains("channelLabel(channel, ofDeviceUID: group.uid)"))
        #expect(!canvas.contains("model.sourceChannelLabel(channel)"))
    }
}

/// Every remembered setting is actually written down.
///
/// This defect has happened three times, always the same way and always to the
/// field added most recently: `tapMuteBehavior`, then `recordingFormat`, then
/// `residentScript`. `persist()` builds a `Preferences` with the memberwise
/// initialiser, every field is an optional `var`, and a field the call forgets
/// to name is filled in as nil — silently. `save` then overwrites the whole
/// blob, so the setting is not merely un-saved, it is *erased*, including by
/// the very edit that set it.
///
/// Nothing catches it. The type compiles, the file is well-formed, the
/// interface shows the value for the rest of the session, and it is gone at the
/// next launch. Both round-trip tests pass, because they encode and decode a
/// `Preferences` rather than watching one being built.
///
/// So this reads the source. Crude, and it is the only thing that would have
/// caught any of the three: what is wrong is a missing line, and a missing line
/// has no runtime behaviour to assert on.
@Suite("Every setting reaches the file")
struct PreferencesCompletenessTests {

    private static var sourceRoot: String {
        GraphLockDisciplineTests.enginePath
            .replacingOccurrences(of: "Sources/YunAudioEngine/RoutingEngine.swift", with: "")
    }

    /// The stored properties of `Preferences`, in declaration order.
    private func declaredFields() throws -> [String] {
        let source = try String(
            contentsOfFile: Self.sourceRoot + "Sources/YunAudioApp/Preferences.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "struct Preferences"))
        let end = try #require(source.range(of: "static let `default`"))
        let body = source[start.upperBound..<end.lowerBound]
        return body.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("var ") else { return nil }
            return trimmed.dropFirst(4).prefix { $0 != ":" && $0 != " " }.description
        }
    }

    /// The argument labels `persist()` actually passes.
    private func persistedFields() throws -> Set<String> {
        let source = try String(
            contentsOfFile: Self.sourceRoot + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "private func persist()"))
        let body = source[start.upperBound...].prefix(6000)
        var found: Set<String> = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let label = String(trimmed[trimmed.startIndex..<colon])
            guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                continue
            }
            found.insert(label)
        }
        return found
    }

    @Test("every field of Preferences is named where it is saved")
    func everyFieldIsPersisted() throws {
        let declared = try declaredFields()
        // The scan has to find the fields, or an empty list passes trivially —
        // which is the failure mode of every check that reads a file.
        #expect(declared.count > 40, "only found \(declared.count) fields")
        let persisted = try persistedFields()
        let forgotten = declared.filter { !persisted.contains($0) }
        #expect(
            forgotten.isEmpty,
            "these are remembered in Preferences and never written: \(forgotten)")
    }

    /// And the defaults name them too, or a fresh install starts with a nil
    /// where the type promised a value.
    @Test("and the default names them as well")
    func defaultsNameThem() throws {
        let source = try String(
            contentsOfFile: Self.sourceRoot + "Sources/YunAudioApp/Preferences.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "static let `default`"))
        let body = source[start.upperBound...].prefix(4000)
        let declared = try declaredFields()
        // Optionals may be left out of the default — nil is a real answer for a
        // device that has not been chosen. What must not be left out is a field
        // with no sensible nil, and those are the non-optional ones.
        let required = declared.filter { field in
            source.contains("var \(field): ") && !source.contains("var \(field): String?")
                && !source.contains("var \(field): Bool?") && !source.contains("var \(field): Float?")
        }
        let missing = required.filter { !body.contains("\($0):") }
        #expect(missing.isEmpty, "not in Preferences.default: \(missing)")
    }
}


/// macOS 26 added `CATapDescription.bundleIDs` and `processRestoreEnabled`,
/// which together are the answer to OBS's issue #9144 — "Application Capture
/// loses audio when application reopens on macOS", open since June 2023, whose
/// workaround in OBS is a button labelled "Restart capture".
///
/// These use the real HAL, because the question is entirely about what the HAL
/// does with what it is given. This project has already been caught once by a
/// `CATapDescription`-adjacent field that reads like a constraint in the header
/// and is silently ignored (`kAudioSubDeviceInputChannelsKey`), and a setting
/// that is accepted and dropped looks exactly like a setting that works.
@Suite("A capture that outlives the application")
struct ProcessTapRestoreTests {

    /// The capability, stated as plainly as it can be: a tap can be created for
    /// an application that is **not running**, and is not even installed. No
    /// process object exists to name, so `bundleIDs` is the only thing holding
    /// it, which is why the two properties have to be set together.
    @Test("a tap can be made for an application that is not running")
    func absentApplication() throws {
        let tap = try ProcessTap(
            processIDs: [], bundleIDs: ["com.yuhuanstudio.nothing.at.all"])
        let held = try #require(tap.systemDescription())
        #expect(held.isProcessRestoreEnabled)
        #expect(held.bundleIDs == ["com.yuhuanstudio.nothing.at.all"])
        // Nothing is attached, which is the point: the tap is waiting for it.
        #expect(held.processes.isEmpty)
    }

    /// The read-back is off the tap object, not off the description this
    /// process is still holding. Asserting our own object would assert that
    /// Swift assigns properties.
    @Test("the HAL keeps both, and reports them back")
    func roundTrip() throws {
        let tap = try ProcessTap(
            processIDs: [], muteBehavior: .mutedWhenTapped,
            bundleIDs: ["com.apple.Music", "com.spotify.client"])
        let held = try #require(ProcessTap.description(of: tap.id))
        #expect(held.isProcessRestoreEnabled)
        #expect(held.bundleIDs.sorted() == ["com.apple.Music", "com.spotify.client"])
        // The fields that were already being set have to still be there: a
        // property added to a description is a chance to overwrite one.
        #expect(held.isPrivate)
        #expect(held.muteBehavior == .mutedWhenTapped)
    }

    /// **The flag was never the missing piece.** `processRestoreEnabled`
    /// defaults to *true* on a fresh `CATapDescription`, so every tap this
    /// application has ever created already had it on — and restored nothing,
    /// because `bundleIDs` defaults to empty and there was consequently nothing
    /// to remember. Setting the flag alone would have been a change with no
    /// effect that looked exactly like a fix.
    ///
    /// This is asserted rather than written in a comment because it is the
    /// whole reason the two properties are set together, and because a future
    /// macOS flipping the default would otherwise turn a working capture into a
    /// silent one with nothing pointing at the cause.
    @Test("restore is on by default and does nothing without bundle identifiers")
    func theFlagWasNeverTheMissingPiece() throws {
        let tap = try ProcessTap(processIDs: [])
        #expect(!tap.restoresProcesses)
        let held = try #require(tap.systemDescription())
        #expect(held.isProcessRestoreEnabled)
        #expect(held.bundleIDs.isEmpty)
    }

    /// And the read-back is a read-back rather than a constant.
    ///
    /// Without this, every assertion above would be satisfied by a HAL that
    /// returns `true` for this property no matter what it was handed — which,
    /// given that the default is already `true`, is not a far-fetched way for
    /// all of this to mean nothing.
    @Test("an explicit refusal comes back as a refusal")
    func explicitFalse() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.isPrivate = true
        description.isProcessRestoreEnabled = false
        var id = AudioObjectID(kAudioObjectUnknown)
        try #require(AudioHardwareCreateProcessTap(description, &id) == noErr)
        defer { AudioHardwareDestroyProcessTap(id) }
        let held = try #require(ProcessTap.description(of: id))
        #expect(!held.isProcessRestoreEnabled)
    }
}
