import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioHAL

@Suite("System voice activity ownership")
struct VoiceActivityOwnershipTests {
    private final class EnablePropertySpy {
        var value: Bool?
        var writes: [Bool] = []
        var acceptsWrites = true

        init(_ value: Bool?) {
            self.value = value
        }

        func read() -> Bool? { value }

        func write(_ newValue: Bool) -> Bool {
            writes.append(newValue)
            guard acceptsWrites else { return false }
            value = newValue
            return true
        }
    }

    private func stop(
        _ controller: inout VoiceActivityEnableController,
        property: EnablePropertySpy
    ) {
        if controller.takeRestore() {
            _ = property.write(false)
        }
    }

    private func routerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/YunAudioApp/RouterModel.swift"),
            encoding: .utf8)
    }

    private func section(
        of source: String,
        from start: String,
        to end: String
    ) throws -> Substring {
        let lower = try #require(source.range(of: start))
        let upper = try #require(
            source.range(of: end, range: lower.upperBound..<source.endIndex))
        return source[lower.lowerBound..<upper.lowerBound]
    }

    @Test("the default route lifecycle writes no global property")
    func defaultIsObserveOnly() {
        #expect(Preferences.default.warnsWhenSpeakingWhileMuted == false)
        let property = EnablePropertySpy(false)
        var controller = VoiceActivityEnableController()

        let started = controller.start(
            policy: .observeOnly,
            readEnabled: property.read,
            setEnabled: property.write)
        #expect(!started)
        stop(&controller, property: property)
        stop(&controller, property: property)

        #expect(property.writes.isEmpty)
        #expect(property.value == false)
    }

    @Test("an owned activation restores exactly once")
    func ownedActivationRestoresOnce() {
        let property = EnablePropertySpy(false)
        var controller = VoiceActivityEnableController()

        let started = controller.start(
            policy: .enableIfNeeded,
            readEnabled: property.read,
            setEnabled: property.write)
        #expect(started)
        #expect(property.writes == [true])

        stop(&controller, property: property)
        stop(&controller, property: property)

        #expect(property.writes == [true, false])
        #expect(property.value == false)
    }

    @Test("an initially enabled detector is preserved without ownership")
    func initialOnIsBorrowed() {
        let property = EnablePropertySpy(true)
        var controller = VoiceActivityEnableController()

        let started = controller.start(
            policy: .enableIfNeeded,
            readEnabled: property.read,
            setEnabled: property.write)
        #expect(started)
        stop(&controller, property: property)

        #expect(property.writes.isEmpty)
        #expect(property.value == true)
    }

    @Test("an unreadable baseline fails closed")
    func unreadableBaselineDoesNotWrite() {
        let property = EnablePropertySpy(nil)
        var controller = VoiceActivityEnableController()

        let started = controller.start(
            policy: .enableIfNeeded,
            readEnabled: property.read,
            setEnabled: property.write)
        #expect(!started)
        stop(&controller, property: property)

        #expect(property.writes.isEmpty)
    }

    @Test("diagnostics distinguishes every cached detector state")
    @MainActor
    func diagnosticsUsesCachedStates() {
        let states = [
            PreferencesWindow.voiceDetectorState(
                isEnabled: false, isAvailable: nil, isRunning: false),
            PreferencesWindow.voiceDetectorState(
                isEnabled: true, isAvailable: nil, isRunning: false),
            PreferencesWindow.voiceDetectorState(
                isEnabled: true, isAvailable: false, isRunning: false),
            PreferencesWindow.voiceDetectorState(
                isEnabled: true, isAvailable: true, isRunning: false),
            PreferencesWindow.voiceDetectorState(
                isEnabled: true, isAvailable: true, isRunning: true),
        ]

        #expect(states.allSatisfy { !$0.isEmpty })
        #expect(Set(states).count == 5)
    }

    @Test("view-facing detector state performs no HAL query")
    func presentationStateIsCached() throws {
        let source = try routerSource()
        let presentation = try section(
            of: source,
            from: "var canDetectVoiceActivity: Bool",
            to: "private func refreshVoiceActivityAvailability()")

        #expect(presentation.contains("voiceActivityAvailability == true"))
        #expect(presentation.contains("private(set) var isDetectingVoiceActivity = false"))
        #expect(!presentation.contains("VoiceActivityWatcher."))
    }

    @Test("structural lint keeps detector cleanup off the route teardown owner")
    func lifecycleCleanupIsolation() throws {
        // VoiceActivityLifecycleWorkerTests executes timeout, invalidation and
        // exact-once ownership. This check only keeps RouterModel wired so the
        // independent detector owner cannot precede the shared route owner.
        let source = try routerSource()
        let routeStop = try section(
            of: source,
            from: "func stop(\n        then completion:",
            to: "/// Admits only another Stop after Core Audio refused")
        let shutdown = try section(
            of: source,
            from: "func shutDown(",
            to: "private func recoverProcessServicesAfterRefusedTermination(")

        let routeCleanup = try #require(
            routeStop.range(of: "_ = requestVoiceActivityCleanup()"))
        let routeOwner = try #require(routeStop.range(of: "engineQueue.async"))
        let routeEngine = try #require(
            routeStop.range(of: "let stop = Self.stopEngineAndRecord(engine)"))
        #expect(routeCleanup.lowerBound < routeEngine.lowerBound)
        #expect(routeOwner.lowerBound < routeEngine.lowerBound)
        #expect(!routeStop.contains("VoiceActivityWatcher"))
        #expect(!routeStop.contains("voiceActivity.stop()"))

        let shutdownCleanup = try #require(
            shutdown.range(of: "let voiceActivity = requestVoiceActivityCleanup()"))
        let detectorOwner = try #require(
            shutdown.range(of: "VoiceActivityShutdownDispatcher.submit("))
        let shutdownEngine = try #require(
            shutdown.range(of: "EngineShutdownDispatcher.submit("))
        #expect(shutdownCleanup.lowerBound < shutdownEngine.lowerBound)
        #expect(shutdownCleanup.lowerBound < detectorOwner.lowerBound)
        #expect(detectorOwner.lowerBound != shutdownEngine.lowerBound)
        #expect(shutdown.contains("work: { Self.stopEngineAndRecord(engine) }"))
        #expect(!shutdown.contains("voiceActivity.stop()"))
    }

    @Test("MainActor rejects every detector event from an obsolete token or source")
    func publicationHasFinalMainActorFence() throws {
        let source = try routerSource()
        let apply = try section(
            of: source,
            from: "private func applyVoiceActivityEvent(",
            to: "private func requestVoiceActivityCleanup()")

        #expect(apply.contains("token == voiceActivityRequestToken"))
        #expect(apply.contains("selectedSourceUID == voiceActivityRequestUID"))
        #expect(apply.contains("warnsWhenSpeakingWhileMuted"))
        #expect(apply.contains("guard isRunning"))
    }
}
