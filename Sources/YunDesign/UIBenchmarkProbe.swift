import Foundation

/// One compositor variable changed by the UI resource benchmark.
///
/// Production has no active variant. Each case exists so a fresh benchmark
/// process can remove one family of drawing work without changing layout or
/// disabling unrelated animation.
public enum YunUIBenchmarkVariant: String, CaseIterable, Sendable {
    case full
    case scrollFadesOff = "scroll-fades-off"
    case cardEffectsOff = "card-effects-off"
    case windowMaterialOff = "window-material-off"
    case lyricFillStatic = "lyric-fill-static"
    case lyricFillLegacy = "lyric-fill-legacy"
}

/// The guarded process environment seen by benchmark-aware views.
///
/// Both flags are required before a variant can affect drawing. Merely exporting
/// a variant name in an ordinary launch therefore leaves the production view
/// tree unchanged.
public struct YunUIBenchmarkConfiguration: Equatable, Sendable {
    /// Whether the launch is the no-audio UI benchmark.
    public let isEnabled: Bool
    /// The exact requested name, retained so an invalid value can be reported.
    public let requestedName: String
    /// The parsed request, or `nil` when the benchmark should refuse it.
    public let requestedVariant: YunUIBenchmarkVariant?

    /// The variant views may apply in this process.
    ///
    /// An unguarded or invalid request deliberately resolves to the complete
    /// production drawing rather than silently removing an effect.
    public var effectiveVariant: YunUIBenchmarkVariant {
        guard isEnabled else { return .full }
        return requestedVariant ?? .full
    }

    /// Application discovery is external work and not part of this benchmark.
    public var suppressesApplicationRefresh: Bool { isEnabled }

    /// Resolves a launch environment without reading mutable global state.
    ///
    /// - Parameter environment: The environment variables to inspect.
    /// - Returns: A guarded configuration suitable for drawing and validation.
    public static func resolve(environment: [String: String]) -> Self {
        let name = environment["YUNAUDIO_UI_BENCHMARK_VARIANT"] ?? "full"
        return Self(
            isEnabled: environment["YUNAUDIO_UI_BENCHMARK"] != nil
                && environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil,
            requestedName: name,
            requestedVariant: YunUIBenchmarkVariant(rawValue: name))
    }

    /// The immutable configuration for the current process.
    public static let process = resolve(environment: ProcessInfo.processInfo.environment)
}
