import SwiftUI

// MARK: - Surfaces

/// A Zinc card. Used for the content inside the glass shell rather than for the
/// shell itself, so the two visual languages stay in their own layers.
public struct YunCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = Yun.Space.md, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(Yun.Palette.card, in: .rect(cornerRadius: Yun.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Yun.Radius.card)
                    .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
            }
            // shadow-xs from the source system. Small enough to read as a lift
            // rather than a drop, which is what keeps the surface calm.
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// A hairline divider at the system's quietest border weight.
public struct YunDivider: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(Yun.Palette.borderHairline)
            .frame(height: 1)
    }
}

/// An empty state.
///
/// A card holding one line of grey text reads as a bug. Centring a glyph above
/// the sentence makes the emptiness look deliberate, which is what it is.
public struct YunEmptyState: View {
    private let symbol: String
    private let message: String

    public init(symbol: String, message: String) {
        self.symbol = symbol
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Yun.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Yun.Palette.textMuted)
            Text(message)
                .font(Yun.Text.body)
                .foregroundStyle(Yun.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 260)
        .padding(.vertical, Yun.Space.xl)
    }
}

// MARK: - Disclosure

/// A collapsible card.
///
/// A menu bar panel has a hard height budget — it drops from under the status
/// item and a laptop screen runs out fast. Sections that are read occasionally
/// rather than watched continuously collapse by default so the ones that matter
/// during a session stay visible without scrolling.
public struct YunDisclosure<Content: View>: View {
    private let title: String
    private let subtitle: String?
    @Binding private var isExpanded: Bool
    private let content: Content

    public init(
        _ title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        _isExpanded = isExpanded
        self.content = content()
    }

    public var body: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: Yun.Space.sm) {
                        Text(title)
                            .font(Yun.Text.label)
                            .foregroundStyle(Yun.Palette.textPrimary)
                        if let subtitle, !isExpanded {
                            Text(subtitle)
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Yun.Space.sm)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Yun.Palette.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if isExpanded { content }
            }
        }
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }
}

// MARK: - Status

public enum YunStatusTone {
    case neutral, success, warning, danger, info

    var color: Color {
        switch self {
        case .neutral: Yun.Palette.textSecondary
        case .success: Yun.Palette.success
        case .warning: Yun.Palette.warning
        case .danger: Yun.Palette.danger
        case .info: Yun.Palette.info
        }
    }
}

/// A small labelled pill. Status colour is carried by the dot and the text, not
/// by a saturated fill — the fill stays neutral so several pills can sit
/// together without the panel turning into a traffic light.
public struct YunStatusPill: View {
    private let text: String
    private let tone: YunStatusTone
    private let showsDot: Bool

    public init(_ text: String, tone: YunStatusTone = .neutral, showsDot: Bool = true) {
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
    }

    public var body: some View {
        HStack(spacing: Yun.Space.xs + 2) {
            if showsDot {
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(Yun.Text.caption)
                .foregroundStyle(tone == .neutral ? Yun.Palette.textSecondary : tone.color)
        }
        .padding(.horizontal, Yun.Space.sm)
        .padding(.vertical, 4)
        .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.pill))
    }
}

// MARK: - Level meter

/// A peak meter drawn as a single `Canvas`.
///
/// Deliberately not a stack of tinted rectangles: this redraws sixty times a
/// second, and a view per segment would put dozens of nodes through layout on
/// every frame for a graphic that is fundamentally one shape.
public struct YunLevelMeter: View {
    private let level: Float
    private let peakHold: Float
    private let segments: Int

    public init(level: Float, peakHold: Float = 0, segments: Int = 24) {
        self.level = level
        self.peakHold = peakHold
        self.segments = segments
    }

    /// Maps amplitude to a 0…1 position on a -60 dBFS scale. Linear amplitude
    /// would leave everything below half scale crammed into the last tenth of
    /// the bar, which is where speech actually lives.
    private func normalized(_ amplitude: Float) -> Double {
        guard amplitude > 0 else { return 0 }
        let db = 20 * log10(Double(amplitude))
        return max(0, min(1, (db + 60) / 60))
    }

    public var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let filled = normalized(level) * Double(segments)
            let holdIndex = Int(normalized(peakHold) * Double(segments))

            for index in 0..<segments {
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap), y: 0,
                    width: width, height: size.height)
                let shape = Path(roundedRect: rect, cornerRadius: 1.5)

                let isLit = Double(index) < filled
                let isHold = index == holdIndex && holdIndex > 0

                // The top two segments read as clipping headroom, so they carry
                // the warning and danger hues rather than the neutral accent.
                let color: Color =
                    if index >= segments - 1 {
                        Yun.Palette.danger
                    } else if index >= segments - 3 {
                        Yun.Palette.warning
                    } else {
                        Yun.Palette.accent
                    }

                if isLit || isHold {
                    context.fill(shape, with: .color(color.opacity(isLit ? 1 : 0.45)))
                } else {
                    context.fill(shape, with: .color(Yun.Palette.elevated))
                }
            }
        }
        .frame(height: 6)
        .accessibilityLabel("input level")
        .accessibilityValue("\(Int(normalized(level) * 100)) percent")
    }
}

// MARK: - Signal path

/// The source → destination graphic, with the live level riding the connector.
public struct YunSignalPath: View {
    private let sourceName: String
    private let destinationName: String
    private let level: Float
    private let isActive: Bool

    public init(source: String, destination: String, level: Float, isActive: Bool) {
        sourceName = source
        destinationName = destination
        self.level = level
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: Yun.Space.sm) {
            endpoint(sourceName, systemImage: "mic.fill")

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    isActive ? Yun.Palette.textSecondary : Yun.Palette.textTertiary
                )
                .frame(width: 14)

            endpoint(destinationName, systemImage: "waveform")
        }
    }

    private func endpoint(_ name: String, systemImage: String) -> some View {
        HStack(spacing: Yun.Space.xs + 2) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(Yun.Palette.textSecondary)
            Text(name)
                .font(Yun.Text.label)
                .foregroundStyle(Yun.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Yun.Space.sm + 2)
        .padding(.vertical, 6)
        .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.control))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

/// A label/value row with the label muted and the value primary, matching the
/// settings rows in the source design system.
public struct YunDetailRow: View {
    private let label: String
    private let value: String
    private let tone: YunStatusTone

    public init(_ label: String, value: String, tone: YunStatusTone = .neutral) {
        self.label = label
        self.value = value
        self.tone = tone
    }

    public var body: some View {
        HStack {
            Text(label)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            Spacer(minLength: Yun.Space.md)
            Text(value)
                .font(Yun.Text.mono)
                .foregroundStyle(tone == .neutral ? Yun.Palette.textPrimary : tone.color)
        }
    }
}
