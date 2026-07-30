import Foundation

/// Decides whether this process is allowed to build the application model.
///
/// A Swift stored-property initializer runs before `App.init()`. Keeping the
/// decision here lets the single-instance claim and the model-free icon path
/// run before `RouterModel` can enumerate hardware or honour auto-start.
enum AppStartup {
    enum Mode: Equatable {
        case duplicate
        case icon
        case render
        case normal
    }

    enum Prepared<Model: Sendable>: Sendable {
        case duplicate
        case icon
        case render(Model)
        case normal(Model)

        var mode: Mode {
            switch self {
            case .duplicate: .duplicate
            case .icon: .icon
            case .render: .render
            case .normal: .normal
            }
        }
    }

    /// Resolves the launch once and constructs exactly the models it requires.
    ///
    /// The factory is injected so the zero/one construction contract can be
    /// asserted without opening CoreAudio, CoreMIDI or HID in a test.
    @MainActor
    static func prepare<Model: Sendable>(
        environment: [String: String],
        claimSingleInstance: () -> Bool,
        makeModel: () -> Model
    ) -> Prepared<Model> {
        if environment["YUNAUDIO_ICON"] != nil {
            return .icon
        }
        if environment["YUNAUDIO_RENDER"] != nil {
            return .render(makeModel())
        }

        let bypassesSingleInstance =
            environment["YUNAUDIO_FLOWCHECK"] != nil
            || environment["YUNAUDIO_SCREENSHOT"] != nil
            || environment["YUNAUDIO_SETTINGS_CHECK"] != nil
        guard bypassesSingleInstance || claimSingleInstance() else {
            return .duplicate
        }
        return .normal(makeModel())
    }
}
