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
            .yunSurface()
    }
}

/// Wraps a row so it lifts under the pointer.
///
/// Everything clickable in the source system has a hover fill; a list that does
/// not respond reads as static text rather than as something to click.
public struct YunHoverRow<Content: View>: View {
    private let content: Content
    private let radius: CGFloat
    @State private var isHovering = false

    public init(radius: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                isHovering ? Yun.Palette.accentSubtle : .clear,
                in: .rect(cornerRadius: radius)
            )
            .contentShape(.rect(cornerRadius: radius))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
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
///
/// The optional value is kept apart from the label and set in the mono face,
/// because a row of these is read by scanning down the numbers: "Buffer 128 f"
/// and "Latency 2.7 ms" only line up if the digits are all the same width.
public struct YunStatusPill: View {
    private let text: String
    private let value: String?
    private let systemImage: String?
    private let tone: YunStatusTone
    private let showsDot: Bool

    public init(
        _ text: String,
        value: String? = nil,
        systemImage: String? = nil,
        tone: YunStatusTone = .neutral,
        showsDot: Bool = true
    ) {
        self.text = text
        self.value = value
        self.systemImage = systemImage
        self.tone = tone
        self.showsDot = showsDot
    }

    private var labelColour: Color {
        tone == .neutral ? Yun.Palette.textSecondary : tone.color
    }

    public var body: some View {
        HStack(spacing: Yun.Space.xs + 2) {
            // A glyph stands in for the dot rather than sitting beside it: two
            // marks in front of two words is a badge, not a pill.
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(labelColour)
            } else if showsDot {
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(Yun.Text.caption)
                .foregroundStyle(labelColour)
            if let value {
                Text(value)
                    .font(Yun.Text.mono)
                    .monospacedDigit()
                    .foregroundStyle(
                        tone == .neutral ? Yun.Palette.textPrimary : tone.color)
            }
        }
        .lineLimit(1)
        // A pill is the width of what is in it. It has to say so itself: the
        // wrapping row asks each of them for a size before it decides where the
        // line breaks, and a pill that answers "as much as you have" would put
        // every row's first pill on a line of its own.
        .fixedSize()
        .padding(.horizontal, Yun.Space.sm)
        .padding(.vertical, 4)
        .modifier(PillSurface())
    }
}

/// The pill's own surface, in whichever look the application is wearing.
///
/// Applied per pill rather than behind the row: a capsule of material is the
/// shape the system's own status chips take, and one sheet behind all of them
/// would read as a bar again — which is the thing the row of pills replaced.
private struct PillSurface: ViewModifier {
    func body(content: Content) -> some View {
        switch YunTheme.shared.style {
        case .flat:
            // The border is the full weight rather than the hairline. A pill
            // fill is one step off the card it usually sits on and no steps at
            // all off the window background, so on light the row along the
            // bottom photographed as loose text with dots beside it — the
            // shapes were there in the tree and not on the screen.
            content
                .background(Yun.Palette.elevated, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(Yun.Palette.border, lineWidth: 1)
                }
        case .glass:
            // With an edge, unlike the cards. Photographed over a plain dark
            // desktop the material had nothing to pick up and the pill lost its
            // shape entirely — a chip the size of two words has no interior for
            // the effect to show in, so the outline is what makes it a pill
            // rather than text lying on the window.
            content
                .glassEffect(.regular, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(Yun.Palette.border, lineWidth: 1)
                }
        }
    }
}

// MARK: - Wrapping row

/// Lays its children out left to right, starting a new line when the next one
/// will not fit.
///
/// `HStack` cannot wrap and `LazyVGrid` would give every cell the same width,
/// which is wrong for content ranging from "REC" to "128 f · 2.67 ms". The
/// status pills have to wrap at the panel's 340 points and must not at the
/// window's 980; one layout that is right at both widths is cheaper than two
/// designs of the same row that can disagree.
public struct YunWrap: Layout {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat

    public init(spacing: CGFloat = Yun.Space.sm, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(within maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : size.width + spacing
            if !current.indices.isEmpty, current.width + advance > maxWidth {
                lines.append(current)
                current = Line(indices: [index], width: size.width, height: size.height)
                continue
            }
            current.indices.append(index)
            current.width += advance
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }

    public func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let lines = lines(within: proposal.width ?? .infinity, subviews: subviews)
        let height =
            lines.map(\.height).reduce(0, +)
            + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
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

    /// Maps amplitude to a 0…1 position.
    ///
    /// Linear on amplitude would cram everything speech does into the last tenth
    /// of the bar; linear on decibels overcorrects, putting a comfortable -11
    /// dBFS at four fifths of full scale so a healthy signal looks like it is
    /// about to clip. The curve below is closer to a broadcast meter: the top
    /// 20 dB take half the bar, the 40 below it take the rest.
    private func normalized(_ amplitude: Float) -> Double {
        guard amplitude > 0 else { return 0 }
        let db = max(-60, min(0, 20 * log10(Double(amplitude))))
        return db >= -20
            ? 0.5 + 0.5 * ((db + 20) / 20)
            : 0.5 * ((db + 60) / 40)
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
        .accessibilityElement()
        .accessibilityLabel(Text(loc("Level")))
        // Decibels rather than a percentage: the percentage is a position on a
        // bar, which is meaningless without seeing the bar.
        .accessibilityValue(
            Text(
                level > 0
                    ? String(format: "%.0f dBFS", 20 * log10(Double(level)))
                    : loc("silent")))
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

/// A determinate progress bar.
///
/// Built from two rounded rectangles rather than from `ProgressView`, for the
/// reason every control in this file is: the system style carries the accent
/// colour, and the accent here is near-black on light and near-white on dark.
public struct YunProgressBar: View {
    private let fraction: Double

    public init(fraction: Double) {
        self.fraction = min(1, max(0, fraction))
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Yun.Palette.elevated)
                Capsule()
                    .fill(Yun.Palette.accent)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityValue(Text("\(Int(fraction * 100))%"))
    }
}
