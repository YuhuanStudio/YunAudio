import Testing
@testable import YunAudioApp

@Suite("Application startup boundary")
struct AppStartupTests {
    @Test("only launches that use the application construct one model")
    @MainActor
    func modelConstructionCount() {
        let cases: [([String: String], Bool, AppStartup.Mode, Int, Int)] = [
            ([:], false, .duplicate, 0, 1),
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
