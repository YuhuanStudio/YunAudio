import CoreAudio
import Testing

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
