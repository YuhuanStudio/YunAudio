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
    private let balanced: Bool
    private let fills: Bool

    /// - Parameters:
    ///   - spacing: Horizontal distance between neighbouring items.
    ///   - lineSpacing: Vertical distance between lines.
    ///   - balanced: Spread the items evenly over the lines rather than filling
    ///     each in turn.
    ///   - fills: Stretch every item on a line to share the width equally.
    ///
    /// The two together are what makes a wrapped row look like a control rather
    /// than like a row that broke. Six tabs across a column that fits five,
    /// packed greedily at their natural widths, gave five and then a lone
    /// sixth; balanced, it gave three and three with a ragged right edge on
    /// both — tidier and still obviously an accident. Filling squares both
    /// edges, and then it reads as a two-by-three grid somebody drew on
    /// purpose. Judged by looking at it, which is the only way this kind of
    /// thing can be judged.
    public init(
        spacing: CGFloat = Yun.Space.sm, lineSpacing: CGFloat = 6,
        balanced: Bool = false, fills: Bool = false
    ) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.balanced = balanced
        self.fills = fills
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(within maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        let widths = subviews.indices.map { subviews[$0].sizeThatFits(.unspecified).width }
        let heights = subviews.indices.map { subviews[$0].sizeThatFits(.unspecified).height }
        return Self.breaks(
            widths: widths, within: maxWidth, spacing: spacing, balanced: balanced
        )
        .map { indices in
            Line(
                indices: indices,
                width: indices.map { widths[$0] }.reduce(0, +)
                    + spacing * CGFloat(max(0, indices.count - 1)),
                height: indices.map { heights[$0] }.max() ?? 0)
        }
    }

    /// Where the lines break, as a pure function of the widths.
    ///
    /// Pulled out so it can be asserted. Greedy packing is right for a row of
    /// pills that happens to be long — it fills each line and the ragged end is
    /// nobody's business. It is wrong for a tab bar: six tabs across a column
    /// that fits five leaves one alone on a second line, which reads as a
    /// mistake rather than as a row that wrapped. Balanced, the same six go
    /// three and three and it reads as deliberate.
    ///
    /// - Parameters:
    ///   - widths: The natural width of each item.
    ///   - maxWidth: The space available to one line.
    ///   - spacing: Horizontal distance between neighbouring items.
    ///   - balanced: Spread the items evenly over as few lines as greedy packing
    ///     would have used. Never uses *more* lines than greedy: the point is the
    ///     shape of the wrap, not a different amount of wrapping.
    /// - Returns: The item indices assigned to each line.
    static func breaks(
        widths: [CGFloat], within maxWidth: CGFloat, spacing: CGFloat, balanced: Bool
    ) -> [[Int]] {
        func pack(_ perLine: Int?) -> [[Int]] {
            var lines: [[Int]] = []
            var current: [Int] = []
            var width: CGFloat = 0
            for index in widths.indices {
                let advance = current.isEmpty ? widths[index] : widths[index] + spacing
                let full = perLine.map { current.count >= $0 } ?? false
                if !current.isEmpty, full || width + advance > maxWidth {
                    lines.append(current)
                    current = [index]
                    width = widths[index]
                    continue
                }
                current.append(index)
                width += advance
            }
            if !current.isEmpty { lines.append(current) }
            return lines
        }

        let greedy = pack(nil)
        guard balanced, greedy.count > 1 else { return greedy }
        // As even as it goes without needing another line. Rounding up, because
        // rounding down would need one more line than greedy used.
        let perLine = Int((Double(widths.count) / Double(greedy.count)).rounded(.up))
        let even = pack(perLine)
        // Only if it did not cost a line. A balanced shape that wraps more is
        // not the trade being made here.
        return even.count <= greedy.count ? even : greedy
    }

    public func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let available = proposal.width ?? .infinity
        let lines = lines(within: available, subviews: subviews)
        let height =
            lines.map(\.height).reduce(0, +)
            + lineSpacing * CGFloat(max(0, lines.count - 1))
        // Filling means taking the whole width, and saying so here is what makes
        // it happen: reporting the natural width instead made the parent size
        // the layout to the pills' own total, so "an equal share of the width"
        // was an equal share of a row that had already shrunk to fit them, and
        // the space to the right of it stayed empty. Visible immediately in the
        // photograph, and invisible in every number.
        let width =
            fills && available.isFinite ? available : (lines.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            // Equal shares of the whole width when filling, so both edges of
            // every line are flush and the wrap looks like a grid.
            let share =
                fills && !line.indices.isEmpty
                ? (bounds.width - spacing * CGFloat(line.indices.count - 1))
                    / CGFloat(line.indices.count) : nil
            for index in line.indices {
                var size = subviews[index].sizeThatFits(.unspecified)
                if let share { size.width = share }
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

/// The cue that a column carries on past the bottom of its frame.
///
/// macOS hides its scrollers until something touches them, so a column that is
/// taller than its frame gives no sign of it at rest: the clip edge lands
/// wherever it lands, and a line of text sliced in half a few points above the
/// footer reads as broken rather than as scrolled. A short fade says it instead.
///
/// **A fixed number of points, not a fraction of the height.** It was a
/// fraction — the mask's last six per cent — and a fraction is a different
/// thing at every window size: about 26 points at the window's minimum and
/// about 49 at full screen on this display, where it stops reading as a fade
/// and starts reading as content someone has rubbed out. A cue is a constant;
/// only what it is a cue *about* varies.
///
/// This lives in the design system rather than beside the one caller so the
/// number, the reasoning and the test have somewhere to be together.
public struct YunScrollFade: ViewModifier {
    /// Deep enough to read as deliberate at a glance, shallow enough that it
    /// never covers a whole row: the rows in this application are 28 points and
    /// up, so the fade cannot swallow one.
    public static let depth: CGFloat = 22

    private let depth: CGFloat

    public init(depth: CGFloat = YunScrollFade.depth) {
        self.depth = depth
    }

    public func body(content: Content) -> some View {
        content.mask(
            VStack(spacing: 0) {
                // Opaque for everything but the last `depth` points, whatever
                // the height is.
                Rectangle().fill(Color.black)
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: depth)
            }
            // The mask must not itself be an obstacle to hit testing; it is
            // only ever alpha.
            .allowsHitTesting(false))
    }
}

extension View {
    /// Fades the bottom `depth` points of a scrolling column. See
    /// `YunScrollFade` for why the depth is a constant.
    public func yunScrollFade(depth: CGFloat = YunScrollFade.depth) -> some View {
        modifier(YunScrollFade(depth: depth))
    }
}
