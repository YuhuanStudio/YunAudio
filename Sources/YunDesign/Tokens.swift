import SwiftUI

/// YunUI's Zinc scale, translated from `styles/yunui.css`.
///
/// The web system flips its accent between themes rather than tinting it — near
/// black on light, near white on dark — and reserves hue entirely for status.
/// That restraint is the whole character of the look, so it is preserved here
/// instead of being "improved" into a coloured accent.
public enum Yun {

    // MARK: Palette

    public enum Palette {
        static func adaptive(light: Color, dark: Color) -> Color {
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? NSColor(dark) : NSColor(light)
                })
        }

        /// Page background.
        public static let background = adaptive(
            light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x09090B))
        /// Raised surfaces: hover fills, tiles, track backgrounds.
        public static let elevated = adaptive(
            light: Color(hex: 0xF4F4F5), dark: Color(hex: 0x18181B))
        /// Card fill.
        public static let card = adaptive(
            light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x141417))

        /// The surface a window's content sits on.
        ///
        /// One step away from the card fill so cards read as raised rather than
        /// as regions marked out by rules. The source system gets this from
        /// `--bg-base` against white cards; a window needs the same separation
        /// or it flattens into a wireframe.
        public static let windowBackground = adaptive(
            light: Color(hex: 0xF7F7F8), dark: Color(hex: 0x0B0B0D))

        /// Hairline separators — the quietest border in the system.
        public static let borderHairline = adaptive(
            light: Color(hex: 0xF4F4F5), dark: Color(hex: 0x27272A))
        public static let border = adaptive(
            light: Color(hex: 0xE4E4E7), dark: Color(hex: 0x3F3F46))
        public static let borderStrong = adaptive(
            light: Color(hex: 0xD4D4D8), dark: Color(hex: 0x52525B))

        public static let textPrimary = adaptive(
            light: Color(hex: 0x09090B), dark: Color(hex: 0xFFFFFF))
        public static let textSecondary = adaptive(
            light: Color(hex: 0x52525B), dark: Color(hex: 0xA1A1AA))
        public static let textTertiary = adaptive(
            light: Color(hex: 0x71717A), dark: Color(hex: 0x71717A))
        public static let textMuted = adaptive(
            light: Color(hex: 0x71717A), dark: Color(hex: 0x52525B))

        /// Text and surfaces over the KTV stage, which is a darkened
        /// photograph rather than a card.
        ///
        /// The stage is the one surface in this application that does not
        /// adapt: it is a cover image with a scrim over it in both appearances,
        /// so `textSecondary` — a grey chosen against a card — is the wrong
        /// colour there in light mode and a different wrong colour in dark. The
        /// KTV views therefore each wrote their own `\.white.opacity(…)`, and by
        /// the time anybody counted there were **seventeen distinct values**
        /// doing the work of five roles: 0.6, 0.62 and 0.66 all meaning
        /// "secondary", 0.08 through 0.18 all meaning "a well or a hairline".
        ///
        /// That is not a stage that was designed darker; it is a stage that
        /// stopped using the design system, one view at a time, because the
        /// system had nothing to offer it. This is the offer.
        public enum OnStage {
            /// Titles and the line being sung.
            public static let primary = Color.white
            /// Labels beside a control, and the lines around the current one.
            public static let secondary = Color.white.opacity(0.72)
            /// Captions, and what a control costs.
            public static let tertiary = Color.white.opacity(0.55)
            /// The lines a long way from the current one.
            public static let faint = Color.white.opacity(0.35)
            /// The well behind a round button.
            public static let well = Color.white.opacity(0.10)
            /// The same well when the control it holds is on.
            public static let wellLit = Color.white.opacity(0.18)
            /// A hairline over the photograph.
            public static let hairline = Color.white.opacity(0.12)
        }

        /// Inverted between themes, as in the source system: near-black on
        /// light, near-white on dark. What every accent falls back to.
        public static let monochromeAccent = adaptive(
            light: Color(hex: 0x18181B), dark: Color(hex: 0xFAFAFA))

        /// The accent in force.
        ///
        /// Computed rather than constant so that choosing a colour reaches
        /// every surface at once. Reading the theme here is also what makes
        /// the change visible: the read is registered with Observation from
        /// inside whatever view body asked for the colour, so the fader, the
        /// meter and the selected tab all repaint together rather than
        /// whenever each next happens to be rebuilt.
        @MainActor public static var accent: Color {
            YunTheme.shared.accent.colour(hue: YunTheme.shared.accentHue)
        }

        /// What is drawn on top of a filled accent. Unchanged by the choice:
        /// every accent this offers is dark on a light appearance and light on
        /// a dark one, so the contrasting side is the same both ways.
        public static let accentForeground = adaptive(
            light: Color(hex: 0xFAFAFA), dark: Color(hex: 0x18181B))

        /// The quiet fill behind a selected row.
        ///
        /// Neutral for the monochrome accent, which is the source system's own
        /// behaviour, and a wash of the accent otherwise — a coloured accent
        /// that left every selection grey would only be visible on a fader.
        @MainActor public static var accentSubtle: Color {
            YunTheme.shared.accent == .monochrome
                ? neutralSubtle : accent.opacity(0.16)
        }

        static let neutralSubtle = adaptive(
            light: Color(hex: 0xF4F4F5), dark: Color(hex: 0x27272A))

        /// The accent resolved to sRGB, for checks that have to assert a colour
        /// rather than look at one.
        ///
        /// A swatch drawn from a setting that never reached the palette looks
        /// exactly like one that did, and the offscreen render is a picture
        /// nobody diffs. Numbers are the only way to know the choice arrived.
        @MainActor public static func accentComponents() -> (
            red: Double, green: Double, blue: Double
        ) {
            guard let resolved = NSColor(accent).usingColorSpace(.sRGB) else {
                return (0, 0, 0)
            }
            return (
                Double(resolved.redComponent), Double(resolved.greenComponent),
                Double(resolved.blueComponent)
            )
        }

        // Status. The only place hue is allowed.
        public static let success = adaptive(
            light: Color(hex: 0x065F46), dark: Color(hex: 0x34D399))
        public static let warning = adaptive(
            light: Color(hex: 0x92400E), dark: Color(hex: 0xFBBF24))
        public static let danger = adaptive(
            light: Color(hex: 0xB91C1C), dark: Color(hex: 0xF87171))
        public static let info = adaptive(
            light: Color(hex: 0x1D4ED8), dark: Color(hex: 0x60A5FA))
    }

    // MARK: Radii

    /// Literal points, not a scale. YunUI learned this the hard way: defining a
    /// `--radius-*` scale collided with Tailwind's reserved namespace and
    /// distorted every corner in the system. The values stay concrete.
    public enum Radius {
        public static let panel: CGFloat = 24
        public static let card: CGFloat = 20
        public static let button: CGFloat = 14
        public static let buttonSmall: CGFloat = 11
        public static let control: CGFloat = 8
        public static let pill: CGFloat = 999
    }

    // MARK: Spacing

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    // MARK: Type

    public enum Text {
        public static let title = Font.system(size: 15, weight: .semibold)
        public static let body = Font.system(size: 13, weight: .regular)
        public static let label = Font.system(size: 12, weight: .medium)
        public static let caption = Font.system(size: 11, weight: .regular)
        /// Numbers that change in place — meters, rates, ratios — so digits do
        /// not shuffle sideways as the value updates.
        public static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    }
}

/// The accents on offer.
///
/// The source system reserves hue entirely for status and inverts its accent
/// between themes instead, and that restraint is why `monochrome` is both the
/// default and first in the list. But a design system that cannot be made
/// somebody's own is a design system they work around, so the alternatives are
/// the system's *own* status hues rather than new colours invented for the
/// purpose — every one of these values already appears in the palette above —
/// plus one free hue for anybody who wants their own.
public enum YunAccent: String, CaseIterable, Identifiable, Sendable {
    case monochrome
    case blue
    case green
    case amber
    case red
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .monochrome: loc("Monochrome")
        case .blue: loc("Blue")
        case .green: loc("Green")
        case .amber: loc("Amber")
        case .red: loc("Red")
        case .custom: loc("Custom")
        }
    }

    /// The pair, light appearance first. Both are needed: a colour picked to
    /// read against white is invisible against near-black, which is exactly
    /// the defect the two-appearance render exists to catch.
    public func colour(hue: Double) -> Color {
        switch self {
        case .monochrome: Yun.Palette.monochromeAccent
        case .blue:
            Yun.Palette.adaptive(light: Color(hex: 0x1D4ED8), dark: Color(hex: 0x60A5FA))
        case .green:
            Yun.Palette.adaptive(light: Color(hex: 0x065F46), dark: Color(hex: 0x34D399))
        case .amber:
            Yun.Palette.adaptive(light: Color(hex: 0x92400E), dark: Color(hex: 0xFBBF24))
        case .red:
            Yun.Palette.adaptive(light: Color(hex: 0xB91C1C), dark: Color(hex: 0xF87171))
        case .custom:
            // Darker and more saturated on light, lighter and less saturated
            // on dark, in the same proportion as the pairs above. Taking the
            // hue at full strength both ways would give a colour that glares
            // in one appearance and vanishes in the other.
            Yun.Palette.adaptive(
                light: Color(hue: hue, saturation: 0.85, brightness: 0.55),
                dark: Color(hue: hue, saturation: 0.55, brightness: 0.95))
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
