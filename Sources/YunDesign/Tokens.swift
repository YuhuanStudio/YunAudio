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

        /// Inverted between themes, as in the source system.
        public static let accent = adaptive(
            light: Color(hex: 0x18181B), dark: Color(hex: 0xFAFAFA))
        public static let accentForeground = adaptive(
            light: Color(hex: 0xFAFAFA), dark: Color(hex: 0x18181B))
        public static let accentSubtle = adaptive(
            light: Color(hex: 0xF4F4F5), dark: Color(hex: 0x27272A))

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
