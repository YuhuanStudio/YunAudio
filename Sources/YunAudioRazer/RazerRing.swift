import Foundation

/// What to draw on the twelve-LED ring.
///
/// Lives here rather than in the application because it is a property of the
/// hardware: the ring's geometry decides what a level looks like on it, and
/// that geometry is device knowledge. Keeping it in a library also makes it
/// testable, which it was not while it lived inside a render loop — checking it
/// through the live device meant racing the router's own metering, so the test
/// was measuring how fast it could read the device rather than what the ring
/// shows.
public enum RazerRing {
    public typealias Colour = (r: UInt8, g: UInt8, b: UInt8)

    public static let dark: Colour = (0, 0, 0)
    /// Loud but not clipping.
    public static let warning: Colour = (255, 170, 0)
    /// At or near full scale.
    public static let danger: Colour = (255, 40, 0)
    public static let muted: Colour = (255, 0, 0)

    public static func solid(_ colour: Colour) -> [Colour] {
        Array(repeating: colour, count: RazerLightingCommand.ledCount)
    }

    /// The ring as a level meter.
    ///
    /// - Parameters:
    ///   - level: Peak amplitude from 0 to 1, already smoothed.
    ///   - colour: The lit colour below the warning region.
    ///   - isMuted: Overrides everything — a muted ring is entirely red.
    /// - Returns: One colour per LED, in device order.
    public static func level(
        _ level: Float, colour: Colour, isMuted: Bool
    ) -> [Colour] {
        let count = RazerLightingCommand.ledCount
        // Muting is the whole ring in red rather than a level of zero: "quiet"
        // and "muted" have to be unmistakable from each other, and an unlit
        // ring is already what silence looks like.
        if isMuted { return Array(repeating: muted, count: count) }

        // Compressed the same way the meters are, so the ring and the bars
        // agree about what "half" means.
        let filled = Double(min(1, pow(min(1, level * 4), 0.5)))
        // Silence is dark. The bottom LED sits at height zero, so without this
        // it stays lit through complete silence and the ring never goes out.
        guard filled > 0.001 else { return Array(repeating: dark, count: count) }

        return (0..<count).map { index in
            // By height rather than by index. Index 0 is at six o'clock and the
            // indices run clockwise, so filling by index sweeps round the ring
            // like a chase; filling by height rises up both sides at once,
            // which is what a level looks like.
            let height = RazerLightingCommand.height(ofLED: index)
            guard height <= filled else { return dark }
            return height > 0.92 ? danger : (height > 0.75 ? warning : colour)
        }
    }

    /// A hue circle, turned by `step`.
    public static func spectrum(step: Int) -> [Colour] {
        let count = RazerLightingCommand.ledCount
        return (0..<count).map { index in
            let position =
                (Double(step) / 90.0 + Double(index) / Double(count))
                .truncatingRemainder(dividingBy: 1)
            return hue(position)
        }
    }

    public static func hue(_ hue: Double) -> Colour {
        let sector = hue * 6
        let offset = sector - sector.rounded(.down)
        let rising = UInt8(offset * 255)
        let falling = UInt8((1 - offset) * 255)
        switch Int(sector) % 6 {
        case 0: return (255, rising, 0)
        case 1: return (falling, 255, 0)
        case 2: return (0, 255, rising)
        case 3: return (0, falling, 255)
        case 4: return (rising, 0, 255)
        default: return (255, 0, falling)
        }
    }
}
