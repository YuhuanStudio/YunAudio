import Foundation

/// Numbers that appear in more than one place, written once.
///
/// A second copy of a format string is a second opinion about what the number
/// means, and the two drift. This file exists because they had: the status bar
/// said "44.1 kHz" and the settings window said "44 kHz" for the same device,
/// because one divided and formatted to one decimal where there was one, and
/// the other divided and took `Int` of the result.
enum Format {

    /// Kilohertz, with the decimal only where there is one.
    ///
    /// 44.1 needs it, and 48 reads as a different kind of number with ".0" on
    /// the end. Truncating instead is not a rounding difference — 44.1 kHz is
    /// the name of the rate, and "44 kHz" is a rate nothing uses.
    static func sampleRate(_ hertz: Double) -> String {
        let kilohertz = hertz / 1000
        return String(
            format: kilohertz == kilohertz.rounded() ? "%.0f kHz" : "%.1f kHz", kilohertz)
    }
}

extension Format {

    /// Milliseconds to two decimal places, which is where a round trip stops
    /// being meaningful: one sample at 48 kHz is 0.02 ms.
    static func milliseconds(_ value: Double) -> String {
        String(format: "%.2f ms", value)
    }

    /// A share of something, as a percentage.
    static func percent(_ fraction: Double) -> String {
        String(format: "%.2f%%", fraction * 100)
    }
}

/// What this project has measured on its own hardware, as numbers rather than
/// as sentences.
///
/// They were literals inside translated strings, which put a measurement in two
/// `.strings` files and meant that changing one meant editing both — and made
/// the interface quietly claim a figure nobody had re-measured since it was
/// typed. The About panel says in as many words that these are ours and that
/// the integrity check measures yours; keeping them here is what makes that
/// sentence honest rather than decorative.
enum Measured {
    /// Microphone in to headphone out, through the router, at 128 frames.
    static let roundTripMilliseconds = 2.67
    static let roundTripFrames = 128
    /// One core's worth of time, while routing with the window closed.
    static let processorShare = 0.004
}
