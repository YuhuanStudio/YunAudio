import SwiftUI

// MARK: - Buttons

/// Buttons, matching `.btn` in `styles/yunui.css`.
///
/// The defining trait of this system is that buttons are *outlined*, not
/// filled: `.btn-primary` is a dark border over a 4% tint of the same colour,
/// with dark text. A solid fill reads as a different design system entirely, so
/// the tints below are the literal values from the stylesheet rather than an
/// interpretation of them.
public struct YunButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost, danger }

    private let kind: Kind
    private let isSmall: Bool

    public init(_ kind: Kind = .secondary, small: Bool = false) {
        self.kind = kind
        isSmall = small
    }

    public func makeBody(configuration: Configuration) -> some View {
        Surface(kind: kind, isSmall: isSmall, configuration: configuration)
    }

    /// A nested view because a `ButtonStyle` has no state of its own, and hover
    /// needs some. Every rule in the source stylesheet has a matching `:hover`;
    /// without it the controls here read as static images of buttons.
    private struct Surface: View {
        let kind: Kind
        let isSmall: Bool
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            let radius = isSmall ? Yun.Radius.buttonSmall : Yun.Radius.button
            let pressed = configuration.isPressed

            configuration.label
                .font(.system(size: isSmall ? 12 : 13, weight: .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, isSmall ? 12 : 18)
                .padding(.vertical, isSmall ? 6 : 9)
                .background(
                    fill(pressed: pressed, hovering: isHovering),
                    in: .rect(cornerRadius: radius)
                )
                .overlay {
                    if let border = borderColor(hovering: isHovering) {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(border, lineWidth: 1)
                    }
                }
                .contentShape(.rect(cornerRadius: radius))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.15), value: pressed)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        }

        private var foreground: Color {
            switch kind {
            case .primary: Yun.Palette.textPrimary
            // Secondary and ghost darken towards primary on hover, which is
            // what the stylesheet does.
            case .secondary:
                isHovering ? Yun.Palette.textPrimary : Yun.Palette.textSecondary
            case .ghost: isHovering ? Yun.Palette.textPrimary : Yun.Palette.textTertiary
            case .danger: Yun.Palette.danger
            }
        }

        private func borderColor(hovering: Bool) -> Color? {
            switch kind {
            case .primary: Yun.Palette.textPrimary
            case .secondary:
                hovering ? Yun.Palette.textTertiary : Yun.Palette.borderStrong
            case .ghost: nil
            case .danger: Yun.Palette.danger.opacity(0.5)
            }
        }

        private func fill(pressed: Bool, hovering: Bool) -> Color {
            let step: Double = pressed ? 2 : (hovering ? 1 : 0)
            return switch kind {
            case .primary: Yun.Palette.textPrimary.opacity(0.04 + 0.02 * step)
            case .secondary: Yun.Palette.textPrimary.opacity(0.02 + 0.02 * step)
            case .ghost: Yun.Palette.textPrimary.opacity(0.04 * step)
            case .danger: Yun.Palette.danger.opacity(0.04 + 0.03 * step)
            }
        }
    }
}

// MARK: - Segmented control

/// `segmented-select.tsx`, rebuilt.
///
/// Each option is a separately bordered pill rather than one grouped control,
/// and selection is signalled by a stronger border plus a subtle fill — never
/// by an accent colour. The system's accent is already near-black or
/// near-white, so tinting a selection would be the one loud thing in the panel.
public struct YunSegmented<Value: Hashable>: View {
    private let options: [(value: Value, title: String)]
    private let wraps: Bool
    @Binding private var selection: Value
    @FocusState private var focused: Value?

    /// - Parameter wraps: Lets the row run onto a second line rather than
    ///   squeezing. A row of six in a 370-point column truncated its first two
    ///   labels to "…" — two tabs that were no longer possible to tell apart,
    ///   in a control whose entire job is telling them apart. An offscreen
    ///   render cannot show it, because it is given whatever width makes the
    ///   content look complete; the photograph of the real window at its
    ///   minimum size is what said so.
    public init(
        selection: Binding<Value>, options: [(value: Value, title: String)],
        wraps: Bool = false
    ) {
        _selection = selection
        self.options = options
        self.wraps = wraps
    }

    public var body: some View {
        Group {
            if wraps {
                YunWrap(spacing: 6, lineSpacing: 6) { buttons }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    buttons
                    Spacer(minLength: 0)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }

    @ViewBuilder private var buttons: some View {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            isSelected ? Yun.Palette.textPrimary : Yun.Palette.textTertiary
                        )
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            isSelected
                                ? Yun.Palette.accentSubtle
                                : Yun.Palette.elevated.opacity(0.5),
                            in: .rect(cornerRadius: Yun.Radius.control)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Yun.Radius.control)
                                .strokeBorder(
                                    isSelected
                                        ? Yun.Palette.borderStrong : Yun.Palette.border,
                                    lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .focused($focused, equals: option.value)
                // The system focus effect is a blue ring, which would be the
                // only saturated colour in an otherwise monochrome panel. The
                // source system draws its own ring in --border-strong instead.
                .focusEffectDisabled()
                .overlay {
                    if focused == option.value {
                        RoundedRectangle(cornerRadius: Yun.Radius.control + 2)
                            .strokeBorder(Yun.Palette.borderStrong, lineWidth: 2)
                            .padding(-2)
                    }
                }
        }
    }
}

// MARK: - Select

/// `custom-select.tsx`, rebuilt.
///
/// Both the trigger and the dropdown are drawn here. Handing the list to
/// `Menu` would give an AppKit pop-up with system metrics, system highlight
/// colour and system corner radius sitting inside a panel that is otherwise
/// entirely Zinc — the one place the borrowed design would visibly stop.
public struct YunSelect<Value: Hashable>: View {
    public struct Option: Identifiable {
        public let value: Value
        public let title: String
        public let detail: String?

        public init(value: Value, title: String, detail: String? = nil) {
            self.value = value
            self.title = title
            self.detail = detail
        }

        public var id: Value { value }
    }

    private let options: [Option]
    @Binding private var selection: Value
    private let placeholder: String
    @State private var isOpen = false
    @FocusState private var isFocused: Bool

    public init(selection: Binding<Value>, placeholder: String = "None", options: [Option]) {
        _selection = selection
        self.options = options
        self.placeholder = placeholder
    }

    private var selected: Option? { options.first { $0.value == selection } }

    public var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Yun.Space.sm) {
                Text(selected?.title ?? placeholder)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        selected == nil ? Yun.Palette.textMuted : Yun.Palette.textPrimary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail = selected?.detail {
                    YunBadge(detail)
                }

                Spacer(minLength: 2)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Yun.Palette.textMuted)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Yun.Palette.elevated.opacity(0.5), in: .rect(cornerRadius: Yun.Radius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Yun.Radius.control)
                    .strokeBorder(
                        isOpen ? Yun.Palette.borderStrong : Yun.Palette.border, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: Yun.Radius.control))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Yun.Radius.control + 2)
                    .strokeBorder(Yun.Palette.borderStrong, lineWidth: 2)
                    .padding(-2)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isOpen)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(options) { option in
                    optionRow(option)
                }
            }
            .padding(4)
            .frame(minWidth: 240)
            .background(Yun.Palette.card)
            .overlay {
                RoundedRectangle(cornerRadius: Yun.Radius.control)
                    .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
            }
            // A popover is its own hosting window, so a suppression applied at
            // the panel's root does not reach in here.
            .focusEffectDisabled()
        }
    }

    private func optionRow(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
            isOpen = false
        } label: {
            HStack(spacing: Yun.Space.sm) {
                Text(option.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Yun.Palette.textPrimary)
                    .lineLimit(1)
                if let detail = option.detail {
                    YunBadge(detail)
                }
                Spacer(minLength: Yun.Space.sm)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Yun.Palette.textPrimary)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Yun.Palette.accentSubtle : .clear,
                in: .rect(cornerRadius: 6)
            )
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// The small neutral chip used for channel counts and units.
public struct YunBadge: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Yun.Palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.pill))
            .overlay {
                RoundedRectangle(cornerRadius: Yun.Radius.pill)
                    .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
            }
    }
}

// MARK: - Fader

/// A horizontal gain fader.
///
/// Drawn rather than using `Slider`, which brings the system accent colour and
/// system knob metrics into a panel that is otherwise entirely Zinc. The value
/// is in decibels because that is how gain is thought about; the caller
/// converts to a linear multiplier.
public struct YunFader: View {
    @Binding private var decibels: Float
    private let range: ClosedRange<Float>

    /// Where a double-click and an option-click put it back to.
    private let unity: Float
    @State private var isDragging = false

    public init(
        decibels: Binding<Float>, range: ClosedRange<Float> = -40...12, unity: Float = 0
    ) {
        _decibels = decibels
        self.range = range
        self.unity = unity
    }

    private var fraction: Double {
        Double((decibels - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var unityFraction: Double {
        Double((unity - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Yun.Palette.elevated)
                    .frame(height: 4)
                Capsule()
                    .fill(Yun.Palette.accent)
                    .frame(width: max(0, min(width, width * fraction)), height: 4)
                // A tick at unity, so the one position that matters can be
                // found without reading the number beside it.
                if range.contains(unity) {
                    Capsule()
                        .fill(Yun.Palette.borderStrong)
                        .frame(width: 1, height: 8)
                        .offset(x: width * unityFraction - 0.5)
                }
                Circle()
                    .fill(Yun.Palette.card)
                    .overlay {
                        Circle().strokeBorder(
                            isDragging ? Yun.Palette.accent : Yun.Palette.borderStrong,
                            lineWidth: isDragging ? 2 : 1)
                    }
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, min(width - 12, width * fraction - 6)))
            }
            .frame(height: 14)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let ratio = Float(max(0, min(1, value.location.x / width)))
                        let target =
                            range.lowerBound
                            + ratio * (range.upperBound - range.lowerBound)
                        // Snap to unity within half a decibel. Every mixer does
                        // this, and without it exactly 0.0 dB is unreachable by
                        // hand on a fader a hundred points wide.
                        decibels = abs(target - unity) < 0.5 ? unity : target
                    }
                    .onEnded { _ in isDragging = false }
            )
            // Back to unity. Both gestures because both are muscle memory:
            // option-click is the Apple convention, double-click is the audio
            // one, and neither costs anything to support.
            .onTapGesture(count: 2) { decibels = unity }
            .modifier(
                OptionClickReset { decibels = unity }
            )
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(Text(loc("Gain")))
        .accessibilityValue(Text(String(format: "%.1f dB", decibels)))
        .accessibilityAdjustableAction { direction in
            // One decibel a step: the range is 52 dB wide, so a percentage step
            // would be too coarse to set a level with.
            switch direction {
            case .increment: decibels = min(range.upperBound, decibels + 1)
            case .decrement: decibels = max(range.lowerBound, decibels - 1)
            @unknown default: break
            }
        }
    }
}

/// A bare 0…1 slider.
///
/// Separate from `YunFader`, which is specifically a gain control in decibels
/// with silence at the bottom. A parameter carries its own range and curve, so
/// what it needs from a control is a position, not an opinion about loudness.
public struct YunSlider: View {
    @Binding private var fraction: Double
    @State private var isHovering = false

    public init(fraction: Binding<Double>) {
        _fraction = fraction
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Yun.Palette.elevated).frame(height: 3)
                Capsule()
                    .fill(Yun.Palette.accent)
                    .frame(width: max(0, min(width, width * fraction)), height: 3)
                Circle()
                    .fill(Yun.Palette.card)
                    .overlay {
                        Circle().strokeBorder(
                            isHovering ? Yun.Palette.textTertiary : Yun.Palette.borderStrong,
                            lineWidth: 1)
                    }
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(width - 10, width * fraction - 5)))
            }
            .frame(height: 12)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { fraction = max(0, min(1, $0.location.x / width)) })
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(fraction * 100))%"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: fraction = min(1, fraction + 0.05)
            case .decrement: fraction = max(0, fraction - 0.05)
            @unknown default: break
            }
        }
    }
}

/// Converts a fader position to the linear multiplier the engine wants.
/// The bottom of the range is silence rather than a very small number, so a
/// fader pulled all the way down is actually off.
public func yunGainMultiplier(decibels: Float, minimum: Float = -40) -> Float {
    decibels <= minimum ? 0 : pow(10, decibels / 20)
}

// MARK: - Toggle

/// A switch in the Zinc language: the track fills with the inverted accent when
/// on, which is the one place a strong value is used deliberately.
public struct YunToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Yun.Palette.textPrimary)
                Spacer(minLength: Yun.Space.md)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(
                            configuration.isOn
                                ? Yun.Palette.accent : Yun.Palette.elevated
                        )
                        .overlay {
                            Capsule().strokeBorder(
                                configuration.isOn ? .clear : Yun.Palette.border, lineWidth: 1)
                        }
                        .frame(width: 32, height: 18)
                    Circle()
                        .fill(
                            configuration.isOn
                                ? Yun.Palette.accentForeground : Yun.Palette.card
                        )
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 2)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.18), value: configuration.isOn)
    }
}

/// A switch with no label layout of its own.
///
/// `YunToggleStyle` lays out a label, a spacer and the switch, which is right
/// when the toggle owns its own label. Beside custom content — a title and a
/// paragraph explaining what the thing costs — the label is empty, and the
/// spacer then expands to whatever width the toggle is given and shoves the
/// switch to the far right. Every row built that way had a hundred points of
/// gutter down its left side and nothing in the code to suggest it.
///
/// This is the same switch with nothing around it, for exactly that case.
public struct YunSwitch: View {
    @Binding private var isOn: Bool

    public init(isOn: Binding<Bool>) { _isOn = isOn }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Yun.Palette.accent : Yun.Palette.elevated)
                    .overlay {
                        Capsule().strokeBorder(
                            isOn ? .clear : Yun.Palette.border, lineWidth: 1)
                    }
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(isOn ? Yun.Palette.accentForeground : Yun.Palette.card)
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.18), value: isOn)
    }
}

/// Runs an action on an option-click, leaving every other click alone.
///
/// SwiftUI's tap gestures carry no modifier flags, so the state of the option
/// key has to be read from the event itself at the moment of the click.
private struct OptionClickReset: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onTapGesture {
            guard NSEvent.modifierFlags.contains(.option) else { return }
            action()
        }
    }
}

/// Picks a hue by dragging along the spectrum itself.
///
/// A full colour well would offer greys and pastels a twelve-LED ring behind a
/// diffuser cannot show. What anybody wants from it is "make it green", and a
/// strip of the actual colours answers that without a dialog.
public struct HueStrip: View {
    @Binding private var hue: Double

    public init(hue: Binding<Double>) {
        _hue = hue
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12)
                                .map { Color(hue: $0, saturation: 1, brightness: 1) },
                            startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, min(width - 14, width * hue - 7)))
            }
            .frame(height: 14)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hue = max(0, min(1, value.location.x / width))
                    })
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(Text(loc("Colour")))
        .accessibilityValue(Text("\(Int(hue * 360))°"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: hue = min(1, hue + 1.0 / 24)
            case .decrement: hue = max(0, hue - 1.0 / 24)
            @unknown default: break
            }
        }
    }
}

/// A slider that runs up the page.
///
/// Not a rotated `YunSlider`: a rotation puts the hit region somewhere other
/// than where the control is drawn, which is fine until somebody tries to drag
/// the bottom band of an equaliser and moves the one beside it. The geometry is
/// worth writing twice.
///
/// It exists for the graphic equaliser, where vertical is not decoration —
/// the shape of the row of handles *is* the curve, and a column of horizontal
/// sliders carries the same numbers and none of the meaning.
public struct YunVerticalSlider: View {
    @Binding private var fraction: Double
    @State private var isDragging = false

    public init(fraction: Binding<Double>) {
        _fraction = fraction
    }

    public var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let filled = max(0, min(1, fraction))
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Yun.Palette.elevated)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                // A tick at the centre, because the position that matters on an
                // equaliser is "not doing anything" and it should be findable
                // without reading a number.
                Capsule()
                    .fill(Yun.Palette.borderStrong)
                    .frame(width: 10, height: 1)
                    .offset(y: -height / 2)
                // Anchored at the centre rather than at the bottom, because
                // this is a control that cuts as well as boosts. Filled from
                // the bottom, a flat equaliser drew ten half-full bars — which
                // reads as "these bands are set to something" when the whole
                // point of flat is that they are not. It also fought the centre
                // tick immediately above, which was already saying where
                // nothing was the right answer.
                //
                // Now the bar is the distance from flat, on the side it was
                // moved: at flat there is nothing to draw, a cut hangs below
                // the tick and a boost stands above it.
                Capsule()
                    .fill(Yun.Palette.accent)
                    .frame(width: 4, height: Self.fill(for: filled, height: height).length)
                    .offset(y: -Self.fill(for: filled, height: height).base)
                Circle()
                    .fill(Yun.Palette.card)
                    .overlay { Circle().strokeBorder(Yun.Palette.borderStrong, lineWidth: 1) }
                    .frame(width: isDragging ? 13 : 11, height: isDragging ? 13 : 11)
                    .offset(y: -(height - 11) * filled)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        fraction = max(0, min(1, 1 - value.location.y / height))
                    }
                    .onEnded { _ in isDragging = false }
            )
            // Double-click to flatten one band, the same gesture the horizontal
            // fader uses to return to unity.
            .onTapGesture(count: 2) { fraction = 0.5 }
        }
    }

    /// Where the bar starts and how long it is, measured up from the bottom.
    ///
    /// Pulled out of the view so it can be asserted. What it has to get right
    /// is the flat case producing nothing at all, and a boost and a cut of the
    /// same size ending up on opposite sides of the centre — neither of which a
    /// view can be asked about.
    public static func fill(
        for fraction: Double, height: Double
    ) -> (base: Double, length: Double) {
        let clamped = max(0, min(1, fraction))
        return (
            base: height * min(0.5, clamped),
            length: max(0, height * abs(clamped - 0.5))
        )
    }
}
