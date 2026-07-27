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
        let radius = isSmall ? Yun.Radius.buttonSmall : Yun.Radius.button
        let pressed = configuration.isPressed

        configuration.label
            .font(.system(size: isSmall ? 12 : 13, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, isSmall ? 12 : 18)
            .padding(.vertical, isSmall ? 6 : 9)
            .background(fill(pressed: pressed), in: .rect(cornerRadius: radius))
            .overlay {
                if let border = borderColor {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(border, lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: radius))
            .animation(.easeOut(duration: 0.15), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Yun.Palette.textPrimary
        case .secondary: Yun.Palette.textSecondary
        case .ghost: Yun.Palette.textTertiary
        case .danger: Yun.Palette.danger
        }
    }

    private var borderColor: Color? {
        switch kind {
        case .primary: Yun.Palette.textPrimary
        case .secondary: Yun.Palette.borderStrong
        case .ghost: nil
        case .danger: Yun.Palette.danger.opacity(0.5)
        }
    }

    /// The stylesheet's tints: 4% for primary, 2% for secondary, transparent
    /// until hover for ghost. Pressed doubles the tint, which is what the
    /// `:hover` rules do.
    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary: Yun.Palette.textPrimary.opacity(pressed ? 0.08 : 0.04)
        case .secondary: Yun.Palette.textPrimary.opacity(pressed ? 0.04 : 0.02)
        case .ghost: Yun.Palette.textPrimary.opacity(pressed ? 0.04 : 0)
        case .danger: Yun.Palette.danger.opacity(pressed ? 0.10 : 0.04)
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
    @Binding private var selection: Value
    @FocusState private var focused: Value?

    public init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 6) {
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
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: selection)
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

    public init(decibels: Binding<Float>, range: ClosedRange<Float> = -40...12) {
        _decibels = decibels
        self.range = range
    }

    private var fraction: Double {
        Double((decibels - range.lowerBound) / (range.upperBound - range.lowerBound))
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
                Circle()
                    .fill(Yun.Palette.card)
                    .overlay { Circle().strokeBorder(Yun.Palette.borderStrong, lineWidth: 1) }
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, min(width - 12, width * fraction - 6)))
            }
            .frame(height: 14)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = Float(max(0, min(1, value.location.x / width)))
                        decibels =
                            range.lowerBound
                            + ratio * (range.upperBound - range.lowerBound)
                    })
        }
        .frame(height: 14)
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
