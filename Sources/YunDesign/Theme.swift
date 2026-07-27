import Observation
import SwiftUI

/// The two looks this application can wear.
///
/// It had been wearing half of each. The menu bar panel floated on Liquid Glass
/// while the window was built entirely from flat Zinc cards, so the same
/// application looked like two applications depending on which surface you
/// opened — and neither look was committed to. Picking one at random for each
/// surface is the one option that was never defensible.
public enum YunStyle: String, CaseIterable, Identifiable, Sendable {
    /// The source design system: opaque cards, hairline borders, a shadow small
    /// enough to read as a lift. Everything is legible against everything.
    case flat
    /// Apple's material. The surfaces take their colour from what is behind
    /// them, which looks alive over a busy desktop and washes out over a plain
    /// one — a real trade rather than a better answer.
    case glass

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flat: loc("Flat")
        case .glass: loc("Glass")
        }
    }

    public var detail: String {
        switch self {
        case .flat: loc("Opaque cards and hairline borders.")
        case .glass: loc("Translucent surfaces that pick up the desktop behind them.")
        }
    }
}

/// The chosen style, observable so every surface follows it at once.
///
/// A global rather than an environment value on purpose: the menu bar panel is
/// hosted outside the window's view tree, so there is no common ancestor to
/// hang an environment value on, and threading it by hand through two
/// hierarchies is how the two surfaces drifted apart to begin with.
@MainActor
@Observable
public final class YunTheme {
    public static let shared = YunTheme()

    /// Defaults to the source system rather than to Apple's, because that is
    /// what this application's design is derived from; glass is the deliberate
    /// departure.
    public var style: YunStyle = .flat

    private init() {}
}

extension View {
    /// The card surface for the current style.
    @ViewBuilder
    public func yunSurface(cornerRadius: CGFloat = Yun.Radius.card) -> some View {
        switch YunTheme.shared.style {
        case .flat:
            self
                .background(Yun.Palette.card, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
                }
                // shadow-xs from the source system. Small enough to read as a
                // lift rather than a drop, which is what keeps the surface calm.
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        case .glass:
            self
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// The background a whole surface sits on. Translucent under glass, so the
    /// material has something to be a material over.
    @ViewBuilder
    public func yunWindowBackground() -> some View {
        switch YunTheme.shared.style {
        case .flat:
            self.background(Yun.Palette.windowBackground)
        case .glass:
            self.background(.ultraThinMaterial)
        }
    }
}

extension View {
    /// The menu bar panel's own shell.
    ///
    /// Glass wants a container so the material is computed once for the whole
    /// popover rather than per card; flat wants an opaque surface, because a
    /// transparent panel with opaque cards inside it is the half-and-half look
    /// this setting exists to end.
    @ViewBuilder
    public func yunPanelShell() -> some View {
        switch YunTheme.shared.style {
        case .flat:
            self.background(
                Yun.Palette.windowBackground, in: .rect(cornerRadius: Yun.Radius.panel))
        case .glass:
            GlassEffectContainer { self }
                .background(.clear)
        }
    }
}
