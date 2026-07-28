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
