import Foundation
import Testing

@testable import YunAudioApp

@Suite("UI resource benchmark boundary")
struct UIResourceBenchmarkTests {
    @Test("the launcher makes the benchmark a guarded no-audio verification run")
    func launcherCarriesEverySafetyGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcher = try String(
            contentsOf: repository.appendingPathComponent("App/benchmark-ui.sh"),
            encoding: .utf8)
        let app = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/YunAudioApp.swift"),
            encoding: .utf8)
        let benchmark = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/UIResourceBenchmark.swift"),
            encoding: .utf8)
        let model = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/RouterModel.swift"),
            encoding: .utf8)

        #expect(launcher.contains("YUNAUDIO_UI_BENCHMARK=1"))
        #expect(launcher.contains("YUNAUDIO_SCREENSHOT_NO_AUDIO=1"))
        #expect(app.contains("UIResourceBenchmark.run(model: model)"))
        #expect(
            model.contains(
                "if Self.isVerificationProcess, !Self.isUIBenchmarkProcess { refreshDevices() }"
            ))
        #expect(
            model.contains(
                "Self.isVerificationProcess && !Self.isUIBenchmarkProcess"))
        #expect(
            benchmark.contains(
                "model.prepareForRendering(refreshesApplications: false)"))
    }
}
