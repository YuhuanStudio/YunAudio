import Testing

@testable import YunAudioApp

@Suite("Lighting background resource use")
struct LightingResourceTests {
    @Test("ten idle minutes schedule no light rendering in every mode")
    func inactiveModesHaveZeroLoops() {
        var loops = 0
        for mode in LightingMode.allCases {
            if let interval = LightingController.workerInterval(
                mode: mode, isSignalActive: false)
            {
                loops += Int(600 / interval)
            }
        }

        // Spectrum alone previously scheduled 18,000 wake-ups in this window.
        #expect(loops == 0)
        #expect(
            LightingController.workerInterval(mode: .level, isSignalActive: true)
                == 1.0 / 30)
        #expect(
            LightingController.workerInterval(mode: .spectrum, isSignalActive: true)
                == 1.0 / 30)
        #expect(
            LightingController.workerInterval(mode: .solid, isSignalActive: true) == nil)
        #expect(
            LightingController.workerInterval(mode: .off, isSignalActive: true) == nil)
        #expect(
            !LightingController.shouldApplyBrightness(
                mode: .level, isSignalActive: false))
        #expect(
            !LightingController.shouldApplyBrightness(
                mode: .spectrum, isSignalActive: false))
        #expect(
            LightingController.shouldApplyBrightness(
                mode: .level, isSignalActive: true))
        #expect(
            LightingController.shouldApplyBrightness(
                mode: .spectrum, isSignalActive: true))
        #expect(
            LightingController.shouldApplyBrightness(
                mode: .solid, isSignalActive: false))
    }

    @Test("only an active level display consumes meter updates")
    func signalUpdateSchedulingMatchesFrameInputs() {
        let pollsPerHour = 20 * 60 * 60

        for mode in LightingMode.allCases {
            var updates = 0
            for _ in 0..<pollsPerHour {
                if LightingController.needsSignalUpdate(
                    mode: mode, isSignalActive: true)
                {
                    updates += 1
                }
            }
            #expect(updates == (mode == .level ? pollsPerHour : 0))
        }

        #expect(
            !LightingController.needsSignalUpdate(
                mode: .level, isSignalActive: false))
    }

    @Test("the router gates the render-state write before reading its meters")
    func routerUsesSignalUpdateGate() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let lightingLap = try #require(router.range(of: "lap(\"lighting\")"))
        let pollEnd = try #require(
            router.range(
                of: "// MARK: Transcription",
                range: lightingLap.upperBound..<router.endIndex))
        let polling = router[lightingLap.lowerBound..<pollEnd.lowerBound]
        let gate = try #require(polling.range(of: "lighting.needsSignalUpdate"))
        let meter = try #require(polling.range(of: "levels.max()"))
        #expect(gate.lowerBound < meter.lowerBound)

        let controller = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LightingController.swift",
            encoding: .utf8)
        let updateComment = try #require(
            controller.range(of: "/// Called from the router's poll"))
        let gateComment = try #require(
            controller.range(
                of: "/// Whether the router's meter poll",
                range: updateComment.upperBound..<controller.endIndex))
        let update = controller[updateComment.lowerBound..<gateComment.lowerBound]
        #expect(update.ranges(of: "renderState.update(level:").count == 1)
    }

    @Test("launch discovery never scans HID on the MainActor first frame")
    func discoveryIsDeferred() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let lighting = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LightingController.swift",
            encoding: .utf8)
        let initStart = try #require(lighting.range(of: "init() {}"))
        let initEnd = try #require(
            lighting.range(
                of: "func refreshDevice()",
                range: initStart.upperBound..<lighting.endIndex))
        let initialisation = lighting[initStart.lowerBound..<initEnd.lowerBound]
        #expect(initialisation.ranges(of: "RazerDevice.discover()").isEmpty)

        let workerStart = try #require(
            lighting.range(of: "private func runDeviceDiscovery("))
        let workerEnd = try #require(
            lighting.range(
                of: "private func finishDeviceDiscovery(",
                range: workerStart.upperBound..<lighting.endIndex))
        let worker = lighting[workerStart.lowerBound..<workerEnd.lowerBound]
        #expect(worker.ranges(of: "RazerDevice.discover()").count == 1)
        #expect(worker.ranges(of: "discoveryQueue.async").count == 1)

        let applyStart = try #require(
            lighting.range(of: "private func applyDiscoveredDevice("))
        let applyEnd = try #require(
            lighting.range(
                of: "/// Called from the router's poll",
                range: applyStart.upperBound..<lighting.endIndex))
        let apply = lighting[applyStart.lowerBound..<applyEnd.lowerBound]
        #expect(apply.ranges(of: "RazerDevice.discover()").isEmpty)
    }

    @Test("a failed device is probed at a bounded rate")
    func failuresBackOff() {
        var backoff = LightingRetryBackoff()
        let frameInterval = 1.0 / 30
        var elapsed = 0.0
        var attempts = 0

        while elapsed < 60 {
            attempts += 1
            elapsed += backoff.failed(frameInterval: frameInterval)
        }

        // The old loop made 1,800 blocking request/reply transactions in this
        // minute. Exponential delays make fifteen, including the first probe.
        #expect(attempts == 15)
        #expect(attempts < 1_800 / 100)
        #expect(elapsed >= 60)
    }

    @Test("one successful frame restores immediate rendering")
    func successResetsBackoff() {
        var backoff = LightingRetryBackoff()
        let frameInterval = 1.0 / 30
        for _ in 0..<20 {
            _ = backoff.failed(frameInterval: frameInterval)
        }
        #expect(backoff.failed(frameInterval: frameInterval) == 8)

        backoff.succeeded()
        #expect(backoff.failed(frameInterval: frameInterval) == frameInterval)
    }
}
