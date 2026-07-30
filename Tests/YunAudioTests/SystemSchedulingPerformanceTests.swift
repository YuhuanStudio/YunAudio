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

        let beginStart = try #require(
            model.range(of: "func beginInitialDeviceDiscovery()"))
        let beginEnd = try #require(
            model.range(
                of: "@ObservationIgnored private var automaticStartAwaitsDeviceHydration",
                range: beginStart.upperBound..<model.endIndex))
        let initialisation = model[beginStart.lowerBound..<beginEnd.lowerBound]
        #expect(
            initialisation.ranges(of: "hydrateConfiguredDevicesAsynchronously()").count == 1)

        let hydrationStart = try #require(
            model.range(of: "private func hydrateConfiguredDevicesAsynchronously()"))
        let hydrationEnd = try #require(
            model.range(
                of: "private func runConfiguredDeviceHydration(",
                range: hydrationStart.upperBound..<model.endIndex))
        let hydration = model[hydrationStart.lowerBound..<hydrationEnd.lowerBound]
        #expect(hydration.contains("guard !deviceDetailUIDs.isEmpty"))
        #expect(hydration.contains("deviceHydrationGate.invalidate()"))
    }

    @Test("production construction schedules zero HAL work before the live run loop")
    func launchInventoryStartsAfterApplicationDidFinish() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let initStart = try #require(model.range(of: "init() {"))
        let initEnd = try #require(
            model.range(
                of: "func beginInitialDeviceDiscovery()",
                range: initStart.upperBound..<model.endIndex))
        let initialisation = model[initStart.lowerBound..<initEnd.lowerBound]
        #expect(
            initialisation.contains("if Self.isVerificationProcess { refreshDevices() }"))
        #expect(initialisation.ranges(of: "DeviceChangeWatcher").isEmpty)
        #expect(initialisation.ranges(of: "runInitialDeviceRefresh").isEmpty)
        #expect(initialisation.ranges(of: "AudioDevices.").isEmpty)

        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        let launchStart = try #require(
            app.range(of: "func applicationDidFinishLaunching("))
        let launchEnd = try #require(
            app.range(
                of: "var flowCheckModel:",
                range: launchStart.upperBound..<app.endIndex))
        let launch = app[launchStart.lowerBound..<launchEnd.lowerBound]
        #expect(launch.ranges(of: "beginInitialDeviceDiscovery()").count == 1)

        let workerStart = try #require(
            model.range(of: "private func runInitialDeviceRefresh("))
        let workerEnd = try #require(
            model.range(
                of: "private func finishInitialDeviceRefresh(",
                range: workerStart.upperBound..<model.endIndex))
        let worker = model[workerStart.lowerBound..<workerEnd.lowerBound]
        #expect(worker.contains("selectedSourceUID: nil"))
        #expect(worker.contains("selectedDestinationUID: nil"))
        #expect(worker.contains("detailUIDs: []"))
        #expect(worker.ranges(of: "readDeviceRefreshSnapshot(").count == 1)
    }

    @Test("unknown inventory never renders a missing-driver verdict")
    func driverWarningWaitsForInventory() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        for path in [
            "Sources/YunAudioApp/MainWindow.swift",
            "Sources/YunAudioApp/PanelView.swift",
            "Sources/YunAudioApp/StatusPills.swift",
        ] {
            let source = try String(
                contentsOfFile: root + path,
                encoding: .utf8)
            #expect(
                source.contains("deviceInventoryIsReady")
                    && source.contains("!model.isDriverInstalled"),
                Comment(rawValue: path))
        }
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
        #expect(initialisation.ranges(of: "refreshPluginsIfNeeded()").count == 1)
        #expect(initialisation.contains("if !enabledPlugins.isEmpty"))
        #expect(initialisation.contains("if lighting.mode != .off"))

        let restore = try #require(initialisation.range(of: "restore()"))
        let deferred = try #require(
            initialisation.range(of: "refreshPluginsIfNeeded()"))
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

    @Test("restored bindings wait until the first live run-loop turn")
    func midiClientIsLazy() throws {
        #expect(
            !MIDIController.requiresClient(
                bindingCount: 0, diagnosticsAreVisible: false, isLearning: false))
        #expect(
            MIDIController.requiresClient(
                bindingCount: 1, diagnosticsAreVisible: false, isLearning: false))
        #expect(
            MIDIController.requiresClient(
                bindingCount: 0, diagnosticsAreVisible: true, isLearning: false))
        #expect(
            MIDIController.requiresClient(
                bindingCount: 0, diagnosticsAreVisible: false, isLearning: true))

        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/MIDIControl.swift",
            encoding: .utf8)
        let installStart = try #require(
            source.range(of: "func installMIDI(startsClientImmediately: Bool)"))
        let installEnd = try #require(
            source.range(
                of: "/// Where a continuous target currently sits",
                range: installStart.upperBound..<source.endIndex))
        let install = source[installStart.lowerBound..<installEnd.lowerBound]
        #expect(install.ranges(of: "MIDIClientCreate").isEmpty)
        #expect(install.ranges(of: "MIDIGetNumberOfSources").isEmpty)
        #expect(install.ranges(of: "midi?.start(").count == 1)
        #expect(install.ranges(of: "midi.publishClientDemand()").count == 1)
        #expect(install.contains("if startsClientImmediately"))
        #expect(install.ranges(of: "PreferencesStore.load()").isEmpty)

        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        #expect(
            router.contains(
                "installMIDI(startsClientImmediately: Self.isVerificationProcess)"))

        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        let launchStart = try #require(
            app.range(of: "func applicationDidFinishLaunching("))
        let launchEnd = try #require(
            app.range(
                of: "var flowCheckModel:",
                range: launchStart.upperBound..<app.endIndex))
        let launch = app[launchStart.lowerBound..<launchEnd.lowerBound]
        #expect(launch.ranges(of: "beginMIDI()").count == 1)

        let controllerStart = try #require(
            source.range(of: "func start(waitUntilReady: Bool = false)"))
        let controllerEnd = try #require(
            source.range(
                of: "private func applyClientUpdate(",
                range: controllerStart.upperBound..<source.endIndex))
        let submission = source[controllerStart.lowerBound..<controllerEnd.lowerBound]
        #expect(submission.ranges(of: "MIDIClientCreate").isEmpty)
        #expect(submission.ranges(of: "MIDIGetNumberOfSources").isEmpty)
        #expect(submission.contains("clientWorker.start"))
    }

    @Test("one thousand CoreMIDI setup notifications run first and latest only")
    func midiSetupChangesAreCoalesced() {
        let gate = MIDISourceRefreshGate()
        var inventories = 0
        for _ in 0..<1_000 {
            if gate.request() { inventories += 1 }
        }
        #expect(inventories == 1)

        #expect(gate.finish())
        inventories += 1
        #expect(!gate.finish())
        #expect(inventories == 2)

        #expect(MIDIController.publicationIsCurrent(2, current: 2))
        #expect(!MIDIController.publicationIsCurrent(1, current: 2))
        #expect(!MIDIController.publicationIsCurrent(2, current: 3))
    }

    @Test("status panel hosting is allocated only on first open")
    func statusPanelIsLazy() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/StatusItem.swift",
            encoding: .utf8)
        let initStart = try #require(source.range(of: "init(model: RouterModel"))
        let initEnd = try #require(
            source.range(
                of: "private var rightClickMenu",
                range: initStart.upperBound..<source.endIndex))
        let initialisation = source[initStart.lowerBound..<initEnd.lowerBound]
        #expect(initialisation.ranges(of: "NSHostingController").isEmpty)

        let factoryStart = try #require(source.range(of: "private func makePanelHost()"))
        let factoryEnd = try #require(
            source.range(
                of: "/// Detaches the panel",
                range: factoryStart.upperBound..<source.endIndex))
        let factory = source[factoryStart.lowerBound..<factoryEnd.lowerBound]
        #expect(factory.ranges(of: "NSHostingController").count == 1)
    }

    @Test("opening the status panel does not take another application's key window")
    func statusPanelDoesNotForceActivation() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/StatusItem.swift",
            encoding: .utf8)
        let showStart = try #require(source.range(of: "private func showPanel("))
        let showEnd = try #require(
            source.range(
                of: "private func makePanelHost()",
                range: showStart.upperBound..<source.endIndex))
        let show = source[showStart.lowerBound..<showEnd.lowerBound]

        #expect(show.contains("popover.show("))
        #expect(!show.contains(".makeKey("))
        #expect(!show.contains(".makeKeyAndOrderFront("))
        #expect(!show.contains("NSApp.activate("))
    }

    @Test("the status button's left-click path reaches only the passive popover")
    func statusButtonUsesPassivePopoverPath() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/StatusItem.swift",
            encoding: .utf8)
        let initStart = try #require(source.range(of: "init(model: RouterModel"))
        let initEnd = try #require(
            source.range(
                of: "private var rightClickMenu",
                range: initStart.upperBound..<source.endIndex))
        let initialisation = source[initStart.lowerBound..<initEnd.lowerBound]
        #expect(initialisation.contains("button.action = #selector(handleClick)"))
        #expect(
            initialisation.contains(
                "button.sendAction(on: [.leftMouseUp, .rightMouseUp])"))

        let clickStart = try #require(source.range(of: "@objc private func handleClick()"))
        let clickEnd = try #require(
            source.range(
                of: "private func showMenu()",
                range: clickStart.upperBound..<source.endIndex))
        let click = source[clickStart.lowerBound..<clickEnd.lowerBound]
        #expect(click.ranges(of: "togglePopover()").count == 1)
        #expect(!click.contains("NSApp.activate("))

        let toggleStart = try #require(source.range(of: "private func togglePopover()"))
        let toggleEnd = try #require(
            source.range(
                of: "/// Attaches the panel",
                range: toggleStart.upperBound..<source.endIndex))
        let toggle = source[toggleStart.lowerBound..<toggleEnd.lowerBound]
        #expect(toggle.ranges(of: "showPanel(from: button)").count == 1)
        #expect(!toggle.contains("NSApp.activate("))
    }

    @Test("panel reopen counting begins before synchronous popover layout")
    func panelReopenMeasurementIncludesFirstDraw() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/UIFlowCheck.swift",
            encoding: .utf8)
        let helperStart = try #require(
            source.range(of: "func openAndShutPanel() async"))
        let helperEnd = try #require(
            source.range(
                of: "// Twice.",
                range: helperStart.upperBound..<source.endIndex))
        let helper = source[helperStart.lowerBound..<helperEnd.lowerBound]
        let counting = try #require(helper.range(of: "BodyCount.isCounting = true"))
        let opening = try #require(
            helper.range(of: "statusItem?.setPanelOpenForCheck(true)"))
        #expect(counting.lowerBound < opening.lowerBound)

        let secondOpen = try #require(
            source.range(
                of: "\"the menu bar panel still draws when it is opened again\""))
        let positiveCount = try #require(
            source.range(
                of: "(openCounts[\"PanelView\"] ?? 0) > 0",
                range: secondOpen.upperBound..<source.endIndex))
        #expect(secondOpen.lowerBound < positiveCount.lowerBound)
    }

    @Test("headphone files are parsed off MainActor only when needed")
    func headphoneProfilesAreLazy() throws {
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
        #expect(initialisation.ranges(of: "refreshHeadphoneProfiles()").isEmpty)
        #expect(initialisation.contains("if !busHeadphoneProfiles.isEmpty"))

        let readStart = try #require(
            model.range(of: "nonisolated private static func readHeadphoneProfiles()"))
        let readEnd = try #require(
            model.range(
                of: "private func runHeadphoneProfileRefresh(",
                range: readStart.upperBound..<model.endIndex))
        let read = model[readStart.lowerBound..<readEnd.lowerBound]
        #expect(read.ranges(of: "contentsOfDirectory").count == 1)
        #expect(read.ranges(of: "String(").count == 1)

        let applyStart = try #require(
            model.range(of: "private func applyHeadphoneProfiles("))
        let applyEnd = try #require(
            model.range(
                of: "/// True when a correction is chosen",
                range: applyStart.upperBound..<model.endIndex))
        let apply = model[applyStart.lowerBound..<applyEnd.lowerBound]
        #expect(apply.ranges(of: "FileManager").isEmpty)
        #expect(apply.ranges(of: "contentsOfDirectory").isEmpty)
        #expect(apply.contains("if profilesChanged || !stale.isEmpty"))
    }

}
