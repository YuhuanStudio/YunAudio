import Foundation
import Testing
@testable import YunAudioApp

@Suite("Application startup boundary")
struct AppStartupTests {
    @Test("every synthetic evidence mode admits exactly zero live services")
    func syntheticEvidencePolicy() {
        let cases: [[String: String]] = [
            ["YUNAUDIO_RENDER": "/tmp/render"],
            ["YUNAUDIO_SETTINGS_CHECK": "1"],
            [
                "YUNAUDIO_SCREENSHOT": "/tmp/shots",
                "YUNAUDIO_SCREENSHOT_NO_AUDIO": "1",
            ],
            [
                "YUNAUDIO_UI_BENCHMARK": "1",
                "YUNAUDIO_SCREENSHOT": "ui-benchmark",
                "YUNAUDIO_SCREENSHOT_NO_AUDIO": "1",
            ],
            // The guard alone is still fail-closed when inherited by a process.
            ["YUNAUDIO_SCREENSHOT_NO_AUDIO": "1"],
            // No-audio must win even if a hardware verification variable leaks in.
            [
                "YUNAUDIO_FLOWCHECK": "1",
                "YUNAUDIO_SCREENSHOT_NO_AUDIO": "1",
            ],
        ]

        var zeroAdmissionModes = 0
        for environment in cases {
            let policy = AppStartup.modelPolicy(environment: environment)
            #expect(policy.kind == .syntheticEvidence)
            #expect(policy.isVerification)
            #expect(policy.liveServiceAdmissionCount == 0)
            #expect(!AppStartup.startsLiveSystemServices(environment: environment))
            if policy.liveServiceAdmissionCount == 0 { zeroAdmissionModes += 1 }
        }
        #expect(zeroAdmissionModes == 6)
    }

    @Test("production and live verification retain their distinct authority")
    func authorisedSystemServicePolicy() {
        let production = AppStartup.modelPolicy(environment: [:])
        #expect(production.kind == .production)
        #expect(!production.isVerification)
        #expect(!production.refreshesDevicesDuringConstruction)
        #expect(production.discoversOptionalServicesDuringConstruction)
        #expect(production.refreshesLightingHardwareDuringConstruction)
        #expect(production.permitsLightingHardwareDiscovery)
        #expect(production.installsGlobalHotkeysDuringConstruction)
        #expect(!production.startsMIDIImmediatelyDuringConstruction)
        #expect(production.startsLiveServicesAfterLaunch)
        #expect(production.permitsAutomaticStart)
        #expect(production.liveServiceAdmissionCount == 6)

        for environment in [
            ["YUNAUDIO_FLOWCHECK": "1"],
            ["YUNAUDIO_SCREENSHOT": "/tmp/shots"],
        ] {
            let verification = AppStartup.modelPolicy(environment: environment)
            #expect(verification.kind == .liveVerification)
            #expect(verification.isVerification)
            #expect(verification.refreshesDevicesDuringConstruction)
            #expect(!verification.discoversOptionalServicesDuringConstruction)
            #expect(!verification.refreshesLightingHardwareDuringConstruction)
            #expect(verification.permitsLightingHardwareDiscovery)
            #expect(verification.installsGlobalHotkeysDuringConstruction)
            #expect(verification.startsMIDIImmediatelyDuringConstruction)
            #expect(verification.startsLiveServicesAfterLaunch)
            #expect(!verification.permitsAutomaticStart)
            #expect(verification.liveServiceAdmissionCount == 5)
        }
    }

    @Test("synthetic evidence constructs zero global shortcut owners")
    func globalShortcutOwnerConstruction() {
        var constructions = 0
        let makeOwner = {
            constructions += 1
            return constructions
        }

        let synthetic = AppStartup.ModelPolicy(kind: .syntheticEvidence)
        #expect(synthetic.makeGlobalShortcutOwner(makeOwner) == nil)
        #expect(constructions == 0)

        let production = AppStartup.ModelPolicy(kind: .production)
        #expect(production.makeGlobalShortcutOwner(makeOwner) == 1)
        #expect(constructions == 1)

        let live = AppStartup.ModelPolicy(kind: .liveVerification)
        #expect(live.makeGlobalShortcutOwner(makeOwner) == 2)
        #expect(constructions == 2)
    }

    @Test("synthetic model and render fixture construct zero machine-service owners")
    @MainActor
    func syntheticModelFixture() {
        let model = RouterModel(
            startupPolicy: AppStartup.ModelPolicy(kind: .syntheticEvidence))

        #expect(model.startupLiveServiceAdmissionCount == 0)
        #expect(model.globalShortcutOwnerCountForDiagnostics == 0)
        #expect(model.midiDemandHandlerCountForDiagnostics == 0)
        #expect(model.lightingRenderThreadAdmissionCountForDiagnostics == 0)
        #expect(!model.deviceInventoryIsReady)
        #expect(model.inputDevices.isEmpty)
        #expect(model.outputDevices.isEmpty)
        #expect(model.pluginRefreshRevision == 0)
        #expect(model.headphoneProfileRefreshRevision == 0)
        #expect(model.availableApps.isEmpty)
        #expect(model.appsRefreshedAt == nil)
        #expect(model.lightingMode == .off)
        #expect(model.restartCount == 0)
        #expect(model.cycleCountForDiagnostics == 0)
        #expect(model.scriptServiceOwnerCountForDiagnostics == 0)

        var scriptCompletions = 0
        let script = model.runScript("while (true) {}") { result in
            scriptCompletions += 1
            #expect(!result.isSuccess)
        }
        #expect(script == .refused(.stopped))
        #expect(scriptCompletions == 1)
        #expect(model.scriptServiceOwnerCountForDiagnostics == 0)

        model.prepareForRendering()

        #expect(model.activeRoutes.count == 2)
        #expect(
            model.activeRoutes.map(\.source.deviceUID) == [
                "preview-source", "preview-source",
            ])
        #expect(model.activeRoutes.map(\.source.channel) == [0, 0])
        #expect(
            model.activeRoutes.map(\.destination.deviceUID) == [
                "preview-destination", "preview-destination",
            ])
        #expect(model.activeRoutes.map(\.destination.channel) == [0, 1])
        #expect(model.routeGains == [1.0, 0.7])
        #expect(model.routeMutes == [false, true])
        #expect(model.levels == [0.28, 0.0])
        #expect(model.appsRefreshedAt == nil)
        #expect(model.restartCount == 0)
        #expect(model.cycleCountForDiagnostics == 0)

        var termination: ApplicationAudioTeardownResult?
        model.shutDown { termination = $0 }
        #expect(termination == .complete)
        #expect(model.activeRoutes.isEmpty)
        #expect(model.scriptServiceOwnerCountForDiagnostics == 0)
        model.finaliseAcceptedTermination()
        #expect(model.scriptServiceOwnerCountForDiagnostics == 0)
    }

    @Test("synthetic transcription availability performs zero Speech probes")
    @MainActor
    func syntheticTranscriptionDoesNotProbeSpeech() {
        var probes = 0
        let reason = RouterModel.transcriptionUnavailableReason(
            liveServicesArePermitted: false,
            probe: {
                probes += 1
                return .noModel
            })

        #expect(reason == nil)
        #expect(probes == 0)
    }

    @Test("policy reaches the model before every construction-time service entry")
    func startupPolicySourceOrder() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        let appType = try #require(app.range(of: "struct YunAudioApp: App"))
        let appInitialiser = try #require(
            app.range(of: "init() {", range: appType.upperBound..<app.endIndex))
        let appSwitch = try #require(
            app.range(of: "switch startup", range: appInitialiser.upperBound..<app.endIndex))
        let launch = app[appInitialiser.lowerBound..<appSwitch.lowerBound]
        let policy = try #require(launch.range(of: "AppStartup.modelPolicy(environment:"))
        let preparation = try #require(launch.range(of: "AppStartup.prepare("))
        let construction = try #require(
            launch.range(of: "RouterModel(startupPolicy: modelPolicy)"))
        #expect(policy.lowerBound < preparation.lowerBound)
        #expect(preparation.lowerBound < construction.lowerBound)

        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let initialiserStart = try #require(
            router.range(of: "init(startupPolicy: AppStartup.ModelPolicy) {"))
        let initialiserEnd = try #require(
            router.range(
                of: "func beginInitialDeviceDiscovery()",
                range: initialiserStart.upperBound..<router.endIndex))
        let initialiser = router[initialiserStart.lowerBound..<initialiserEnd.lowerBound]
        let assignment = try #require(
            initialiser.range(of: "self.startupPolicy = startupPolicy"))
        let shortcuts = try #require(
            initialiser.range(of: "startupPolicy.makeGlobalShortcutOwner"))
        let inventory = try #require(
            initialiser.range(of: "startupPolicy.refreshesDevicesDuringConstruction"))
        #expect(assignment.lowerBound < shortcuts.lowerBound)
        #expect(shortcuts.lowerBound < inventory.lowerBound)
        #expect(
            initialiser.contains(
                "if startupPolicy.startsLiveServicesAfterLaunch {\n            installMIDI("))

        let renderStart = try #require(
            router.range(of: "func prepareForRendering(refreshesApplications: Bool = true)"))
        let renderEnd = try #require(
            router.range(
                of: "/// Moves the fixture to a moment",
                range: renderStart.upperBound..<router.endIndex))
        let render = router[renderStart.lowerBound..<renderEnd.lowerBound]
        #expect(render.contains("let sourceUID = selectedSource?.uid ?? \"preview-source\""))
        #expect(render.contains("\"preview-destination\""))
        #expect(render.ranges(of: "AudioDevice(").isEmpty)
    }

    @Test("only launches that use the application construct one model")
    @MainActor
    func modelConstructionCount() {
        let cases: [([String: String], Bool, AppStartup.Mode, Int, Int)] = [
            ([:], false, .duplicate, 0, 1),
            (["YUNAUDIO_BUNDLE_CHECK": "1"], false, .bundleCheck, 0, 0),
            (["YUNAUDIO_ICON": "/tmp/icon"], false, .icon, 0, 0),
            (["YUNAUDIO_RENDER": "/tmp/render"], false, .render, 1, 0),
            ([:], true, .normal, 1, 1),
            (["YUNAUDIO_FLOWCHECK": "1"], false, .normal, 1, 0),
            (["YUNAUDIO_SCREENSHOT": "/tmp/shots"], false, .normal, 1, 0),
            (["YUNAUDIO_SETTINGS_CHECK": "1"], false, .normal, 1, 0),
        ]

        for (environment, claimResult, expectedMode, expectedModels, expectedClaims) in cases {
            var models = 0
            var claims = 0
            let prepared = AppStartup.prepare(
                environment: environment,
                claimSingleInstance: {
                    claims += 1
                    return claimResult
                },
                makeModel: {
                    models += 1
                    return models
                })

            #expect(prepared.mode == expectedMode)
            #expect(models == expectedModels)
            #expect(claims == expectedClaims)
        }
    }
}
