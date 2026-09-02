import Foundation

/// Decides whether this process is allowed to build the application model.
///
/// A Swift stored-property initializer runs before `App.init()`. Keeping the
/// decision here lets the single-instance claim and the model-free icon path
/// run before `RouterModel` can enumerate hardware or honour auto-start.
enum AppStartup {
    /// The model's authority to open machine-owned services during launch.
    ///
    /// UI evidence gets a model because it needs the real view hierarchy, but
    /// that model must be synthetic from its first instruction. Suppressing
    /// discovery later in the application delegate is too late: model
    /// construction used to enumerate HAL and open CoreMIDI before that branch.
    struct ModelPolicy: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case production
            case liveVerification
            case syntheticEvidence
        }

        let kind: Kind

        var isVerification: Bool { kind != .production }
        var refreshesDevicesDuringConstruction: Bool {
            kind == .liveVerification
        }
        var discoversOptionalServicesDuringConstruction: Bool {
            kind == .production
        }
        var refreshesLightingHardwareDuringConstruction: Bool {
            kind == .production
        }
        var permitsLightingHardwareDiscovery: Bool {
            kind != .syntheticEvidence
        }
        var installsGlobalHotkeysDuringConstruction: Bool {
            kind != .syntheticEvidence
        }
        var startsMIDIImmediatelyDuringConstruction: Bool {
            kind == .liveVerification
        }
        var startsLiveServicesAfterLaunch: Bool {
            kind != .syntheticEvidence
        }
        var permitsAutomaticStart: Bool { kind == .production }

        /// Constructs the Carbon owner only for a launch allowed to claim keys.
        ///
        /// A lazy property is not sufficient: termination would read it and
        /// install the handler for the first time while trying to tear it down.
        /// Keeping construction behind this closure makes zero owners an
        /// executable assertion rather than an inference from source order.
        func makeGlobalShortcutOwner<Owner>(_ make: () -> Owner) -> Owner? {
            guard installsGlobalHotkeysDuringConstruction else { return nil }
            return make()
        }

        /// A numeric tripwire for every entry point which can wake system state.
        ///
        /// Tests assert this is exactly zero for every synthetic launch. Keeping
        /// the sum here makes adding another entry point a deliberate policy and
        /// test change rather than an unmeasured boolean hidden in model setup.
        var liveServiceAdmissionCount: Int {
            [
                refreshesDevicesDuringConstruction,
                discoversOptionalServicesDuringConstruction,
                refreshesLightingHardwareDuringConstruction,
                permitsLightingHardwareDiscovery,
                installsGlobalHotkeysDuringConstruction,
                startsMIDIImmediatelyDuringConstruction,
                startsLiveServicesAfterLaunch,
                permitsAutomaticStart,
            ].count(where: { $0 })
        }
    }

    enum Mode: Equatable {
        case duplicate
        case bundleCheck
        case icon
        case render
        case normal
    }

    enum Prepared<Model: Sendable>: Sendable {
        case duplicate
        case bundleCheck
        case icon
        case render(Model)
        case normal(Model)

        var mode: Mode {
            switch self {
            case .duplicate: .duplicate
            case .bundleCheck: .bundleCheck
            case .icon: .icon
            case .render: .render
            case .normal: .normal
            }
        }
    }

    /// Resolves machine-service authority before model construction.
    ///
    /// The no-audio guard wins over every live verification spelling. This is
    /// fail-closed deliberately: an inherited guard may make a normal launch
    /// synthetic, but it can never turn a no-hardware gate into a HAL client.
    static func modelPolicy(environment: [String: String]) -> ModelPolicy {
        if environment["YUNAUDIO_RENDER"] != nil
            || environment["YUNAUDIO_UI_BENCHMARK"] != nil
            || environment["YUNAUDIO_SETTINGS_CHECK"] != nil
            || environment["YUNAUDIO_UPDATE_CHECK"] != nil
            || environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil
        {
            return ModelPolicy(kind: .syntheticEvidence)
        }
        if environment["YUNAUDIO_FLOWCHECK"] != nil
            || environment["YUNAUDIO_SCREENSHOT"] != nil
        {
            return ModelPolicy(kind: .liveVerification)
        }
        return ModelPolicy(kind: .production)
    }

    /// Whether the delegate may start deferred CoreMIDI and HAL services.
    static func startsLiveSystemServices(environment: [String: String]) -> Bool {
        modelPolicy(environment: environment).startsLiveServicesAfterLaunch
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
        if environment["YUNAUDIO_BUNDLE_CHECK"] != nil {
            return .bundleCheck
        }
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
            || environment["YUNAUDIO_UPDATE_CHECK"] != nil
        guard bypassesSingleInstance || claimSingleInstance() else {
            return .duplicate
        }
        return .normal(makeModel())
    }
}
