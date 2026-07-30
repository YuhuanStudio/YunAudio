import CoreAudio
import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioHAL

@Suite("System scheduling performance")
struct SystemSchedulingPerformanceTests {
    @Test("an inherited auto-start value cannot silently start a route")
    func autoStartNeedsCurrentConsent() {
        #expect(
            !RouterModel.restoredAutoStart(
                savedEnabled: true,
                consentVersion: RouterModel.autoStartConsentVersion - 1))
        #expect(
            RouterModel.restoredAutoStart(
                savedEnabled: true,
                consentVersion: RouterModel.autoStartConsentVersion))
        #expect(
            !RouterModel.restoredAutoStart(
                savedEnabled: false,
                consentVersion: RouterModel.autoStartConsentVersion))
    }

    @Test("one thousand notifications start only the first and latest refresh")
    func deviceRefreshIsFirstAndLatest() throws {
        var gate = LatestRefreshGate()
        let firstRequest = gate.request()
        let first = try #require(firstRequest)
        var enumerations = 1

        for _ in 1..<1_000 {
            if gate.request() != nil { enumerations += 1 }
        }

        guard case .start(let latest) = gate.finish(first) else {
            Issue.record("the notification burst did not retain its latest refresh")
            return
        }
        enumerations += 1
        #expect(gate.finish(latest) == .idle)
        #expect(enumerations == 2)
    }

    @Test("a synchronous snapshot makes an older queued answer obsolete")
    func deviceRefreshGenerationRejectsOldResult() throws {
        var gate = LatestRefreshGate()
        let oldRequest = gate.request()
        let old = try #require(oldRequest)
        gate.invalidate()

        #expect(!gate.accepts(old))
        #expect(gate.finish(old) == .obsolete)
    }

    @Test("one thousand identical HAL inventories deliver no refresh")
    func identicalDeviceInventoriesAreSuppressed() {
        let original: Set<AudioObjectID> = [12, 34, 56]
        let gate = DeviceInventoryGate(initial: original)
        var deliveries = 0

        for _ in 0..<1_000 {
            if gate.shouldDeliver(original) { deliveries += 1 }
        }
        #expect(deliveries == 0)

        #expect(gate.shouldDeliver([12, 34, 78]))
        deliveries += 1
        #expect(!gate.shouldDeliver([12, 34, 78]))
        #expect(!gate.shouldDeliver(nil))
        #expect(deliveries == 1)
    }

    @Test("no configured route asks no endpoint for live format capabilities")
    func noRouteHasNoDetailedDevices() {
        let details = RouterModel.deviceDetailUIDs(
            source: nil, destination: nil, monitor: nil,
            additionalSources: [], additionalDestinations: [])

        #expect(details.isEmpty)
        #expect(!details.contains("unselected-bluetooth"))
    }

    @Test("device snapshot application contains no HAL call")
    func deviceSnapshotCrossesMainActorAsValues() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let applyStart = try #require(
            model.range(of: "private func applyDeviceRefreshSnapshot("))
        let applyEnd = try #require(
            model.range(
                of: "func refreshDevices()",
                range: applyStart.upperBound..<model.endIndex))
        let apply = model[applyStart.lowerBound..<applyEnd.lowerBound]

        #expect(apply.ranges(of: "AudioDevices.").isEmpty)
        #expect(apply.ranges(of: ".hardwareGain(").isEmpty)
        #expect(apply.ranges(of: ".playThrough(").isEmpty)
        #expect(apply.ranges(of: ".hasSettableVolume(").isEmpty)

        let watcher = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/DeviceChangeWatcher.swift",
            encoding: .utf8)
        #expect(watcher.ranges(of: "kAudioHardwarePropertyDefaultOutputDevice").isEmpty)
        #expect(watcher.ranges(of: "kAudioHardwarePropertyDefaultInputDevice").isEmpty)
    }

    @Test("restore hydrates configured endpoints directly exactly once")
    func restoreHydrationDoesNotEnumerateTheMachine() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let runStart = try #require(
            model.range(of: "private func runConfiguredDeviceHydration("))
        let runEnd = try #require(
            model.range(
                of: "private func finishConfiguredDeviceHydration(",
                range: runStart.upperBound..<model.endIndex))
        let run = model[runStart.lowerBound..<runEnd.lowerBound]
        #expect(run.ranges(of: "AudioDevices.device(uid:").count == 1)
        #expect(run.ranges(of: "AudioDevices.all(").isEmpty)

        let initStart = try #require(model.range(of: "init() {"))
        let initEnd = try #require(
            model.range(
                of: "// MARK: Push to talk",
                range: initStart.upperBound..<model.endIndex))
        let initialisation = model[initStart.lowerBound..<initEnd.lowerBound]
        #expect(
            initialisation.ranges(of: "hydrateConfiguredDevicesAsynchronously()").count == 1)
    }

    @Test("Audio Unit registry discovery is absent from the first MainActor frame")
    func pluginRegistryIsDeferred() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let initStart = try #require(model.range(of: "init() {"))
        let initEnd = try #require(
            model.range(
                of: "// MARK: Push to talk",
                range: initStart.upperBound..<model.endIndex))
        let initialisation = model[initStart.lowerBound..<initEnd.lowerBound]
        #expect(initialisation.ranges(of: "refreshPlugins()").isEmpty)
        #expect(initialisation.ranges(of: "AudioUnitPlugins.installed()").isEmpty)
        #expect(initialisation.ranges(of: "refreshPluginsAsynchronously()").count == 1)

        let restore = try #require(initialisation.range(of: "restore()"))
        let deferred = try #require(
            initialisation.range(of: "refreshPluginsAsynchronously()"))
        #expect(restore.lowerBound < deferred.lowerBound)

        let workerStart = try #require(
            model.range(of: "private func runPluginRefresh("))
        let workerEnd = try #require(
            model.range(
                of: "private func finishPluginRefresh(",
                range: workerStart.upperBound..<model.endIndex))
        let worker = model[workerStart.lowerBound..<workerEnd.lowerBound]
        #expect(worker.ranges(of: "AudioUnitPlugins.installed()").count == 1)
        #expect(worker.ranges(of: "systemDiscoveryQueue").count == 1)

        let applyStart = try #require(
            model.range(of: "private func applyPluginRefresh("))
        let applyEnd = try #require(
            model.range(
                of: "func addPlugin(",
                range: applyStart.upperBound..<model.endIndex))
        let apply = model[applyStart.lowerBound..<applyEnd.lowerBound]
        #expect(apply.ranges(of: "AudioUnitPlugins.installed()").isEmpty)
    }

}
