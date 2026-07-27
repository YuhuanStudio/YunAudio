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
