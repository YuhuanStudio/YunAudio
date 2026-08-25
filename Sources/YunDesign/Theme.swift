import AppKit
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

/// Light, dark, or whatever the system is doing.
///
/// A separate axis from `YunStyle`, and confusing the two is easy: style is
/// *what the surfaces are made of*, appearance is *which end of the palette
/// they are drawn from*. Glass in daylight and flat at night are both real
/// combinations, so neither setting can stand in for the other.
public enum YunAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: loc("System")
        case .light: loc("Light")
        case .dark: loc("Dark")
        }
    }

    /// What the application's appearance is set to. Nil hands the decision
    /// back to the system, which is not the same as asking for light.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
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

    /// Light, dark or the system's own choice, applied to the whole process.
    public var appearance: YunAppearance = .system {
        didSet {
            guard oldValue != appearance else { return }
            store(appearance.rawValue, as: Key.appearance)
            applyAppearance()
        }
    }

    /// Which colour selection, focus and level are drawn in.
    public var accent: YunAccent = .monochrome {
        didSet {
            guard oldValue != accent else { return }
            store(accent.rawValue, as: Key.accent)
        }
    }

    /// The hue `YunAccent.custom` uses, 0…1 around the wheel.
    public var accentHue: Double = 0.58 {
        didSet {
            guard oldValue != accentHue else { return }
            UserDefaults.standard.set(accentHue, forKey: Key.accentHue)
        }
    }

    /// The language the interface is read in.
    ///
    /// Stored here as well as in `YunStrings` on purpose. `YunStrings` is where
    /// the value has to live, because a lookup can happen before this object
    /// exists; this copy is what makes the change *observable*, so that every
    /// `loc()` in every open window is invalidated the moment it moves.
    public var language: YunLanguage = YunStrings.language {
        didSet {
            guard oldValue != language else { return }
            YunStrings.language = language
        }
    }

    private enum Key {
        static let appearance = "com.yuhuanstudio.yunaudio.appearance"
        static let accent = "com.yuhuanstudio.yunaudio.accent"
        static let accentHue = "com.yuhuanstudio.yunaudio.accentHue"
    }

    /// These are not in the router's preferences file, and deliberately so:
    /// that file is decoded once a model exists, and by then the first window
    /// has already been drawn in the wrong colours. `UserDefaults` is readable
    /// from the design system with nothing else having run.
    private init() {
        let defaults = UserDefaults.standard
        appearance =
            defaults.string(forKey: Key.appearance)
            .flatMap(YunAppearance.init(rawValue:)) ?? .system
        accent =
            defaults.string(forKey: Key.accent).flatMap(YunAccent.init(rawValue:))
            ?? .monochrome
        if defaults.object(forKey: Key.accentHue) != nil {
            accentHue = defaults.double(forKey: Key.accentHue)
        }
    }

    private func store(_ value: String, as key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Puts the chosen appearance on the application.
    ///
    /// Called at launch as well as on every change: `NSApp` does not exist yet
    /// while the scene is being built, so the setter alone would leave the
    /// first launch after a change looking like the setting had not stuck.
    public func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// What is actually on disk, for the flow check to assert against.
    ///
    /// Reading the properties back would only prove that a setter assigns, and
    /// a preference that does not survive the process is exactly the defect
    /// worth catching.
    public static func persisted() -> (
        appearance: YunAppearance, accent: YunAccent, hue: Double?, language: YunLanguage
    ) {
        let defaults = UserDefaults.standard
        return (
            defaults.string(forKey: Key.appearance)
                .flatMap(YunAppearance.init(rawValue:)) ?? .system,
            defaults.string(forKey: Key.accent).flatMap(YunAccent.init(rawValue:))
                ?? .monochrome,
            defaults.object(forKey: Key.accentHue) == nil
                ? nil : defaults.double(forKey: Key.accentHue),
            YunStrings.language
        )
    }
}

extension View {
    /// The card surface for the current style.
    @ViewBuilder
    public func yunSurface(cornerRadius: CGFloat = Yun.Radius.card) -> some View {
        let benchmark = YunUIBenchmarkConfiguration.process
        switch YunTheme.shared.style {
        case .flat:
            // The fill and hairline already separate cards from the window.
            // A 5% two-point shadow looked almost identical but made the real
            // 120 Hz window-movement maximum rise from 7.85 to 13.83 ms.
            self
                .background(Yun.Palette.card, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
                }
        case .glass:
            if benchmark.effectiveVariant == .cardEffectsOff {
                self
            } else if #available(macOS 26.0, *) {
                self
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    // Material alone disappears over a quiet desktop, most
                    // visibly in the light appearance: headings and controls
                    // then float with no indication of which ones belong
                    // together. The hairline preserves the glass while making
                    // the card boundary survive every backdrop.
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
                    }
            } else {
                // Below macOS 26 there is no Liquid Glass, and this is the
                // nearest thing the platform has ever had. It is not a
                // downgrade of the design so much as the same idea in the
                // materials of the day: translucency over the desktop, with the
                // hairline doing exactly the job it does above — keeping the
                // card boundary when the backdrop is quiet.
                //
                // Worth the branch. Requiring macOS 26 for the whole
                // application to get one decoration would have cost every
                // machine older than a year, for a look.
                self
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
                    }
            }
        }
    }

    /// The background a whole surface sits on. Translucent under glass, so the
    /// material has something to be a material over.
    @ViewBuilder
    public func yunWindowBackground() -> some View {
        let benchmark = YunUIBenchmarkConfiguration.process
        switch YunTheme.shared.style {
        case .flat:
            self.background(Yun.Palette.windowBackground)
        case .glass:
            if benchmark.effectiveVariant == .windowMaterialOff {
                self.background(Yun.Palette.windowBackground)
            } else {
                self.background(.ultraThinMaterial)
            }
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
            // The container exists so the material is computed once for the
            // whole popover rather than per card. Without it, the material
            // itself still is — it is the sharing that is lost, not the look.
            if #available(macOS 26.0, *) {
                GlassEffectContainer { self }
                    .background(.clear)
            } else {
                self.background(
                    .ultraThinMaterial, in: .rect(cornerRadius: Yun.Radius.panel))
            }
        }
    }
}
