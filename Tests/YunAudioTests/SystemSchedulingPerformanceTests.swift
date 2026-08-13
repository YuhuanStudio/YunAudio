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

    @Test("channel-label getters never trigger lazy profile filesystem work")
    func profileSnapshotCrossesTheDiscoveryLane() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let getterStart = try #require(model.range(of: "var sourceChannelNames:"))
        let getterEnd = try #require(
            model.range(
                of: "/// Label for one channel",
                range: getterStart.upperBound..<model.endIndex))
        let getters = model[getterStart.lowerBound..<getterEnd.lowerBound]

        #expect(getters.contains("let deviceProfileLibrary"))
        #expect(getters.contains("in: deviceProfileLibrary"))
        #expect(getters.ranges(of: "DeviceChannelNames.shared").isEmpty)
        #expect(getters.ranges(of: "DeviceProfileLibrary.standard").isEmpty)
        #expect(getters.ranges(of: "FileManager").isEmpty)

        let readerStart = try #require(
            model.range(of: "nonisolated static func readDeviceRefreshSnapshot("))
        let readerEnd = try #require(
            model.range(
                of: "private func applyDeviceInventory(",
                range: readerStart.upperBound..<model.endIndex))
        let reader = model[readerStart.lowerBound..<readerEnd.lowerBound]
        #expect(reader.ranges(of: "DeviceChannelNames.shared").count == 1)

        let applyStart = try #require(model.range(of: "private func applyDeviceInventory("))
        let applyEnd = try #require(
            model.range(
                of: "private func applyDeviceControlSnapshot(",
                range: applyStart.upperBound..<model.endIndex))
        let apply = model[applyStart.lowerBound..<applyEnd.lowerBound]
        #expect(apply.contains("deviceProfileLibrary = snapshot.deviceProfiles.library"))
        #expect(apply.ranges(of: "DeviceChannelNames.shared").isEmpty)
    }

    @Test("selected words and transcript storage leave MainActor before filesystem work")
    func localDocumentsUseBoundedOwners() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)

        let wordsStart = try #require(model.range(of: "func openWords(at url: URL)"))
        let wordsEnd = try #require(
            model.range(
                of: "private func adoptHandWordsResources(",
                range: wordsStart.upperBound..<model.endIndex))
        let words = model[wordsStart.lowerBound..<wordsEnd.lowerBound]
        #expect(words.contains("if isVerificationProcess"))
        #expect(words.ranges(of: "HandWordsResourceLoader.load(request)").count == 1)
        #expect(words.ranges(of: "handWordsResourceWorker.submit(").count == 1)
        #expect(words.ranges(of: "String(contentsOf").isEmpty)
        #expect(words.ranges(of: "Data(contentsOf").isEmpty)
        #expect(words.ranges(of: "FileManager").isEmpty)

        let transcriptStart = try #require(model.range(of: "func saveTranscript() -> Bool"))
        let transcriptEnd = try #require(
            model.range(
                of: "private func finishTranscriptSave(",
                range: transcriptStart.upperBound..<model.endIndex))
        let transcript = model[transcriptStart.lowerBound..<transcriptEnd.lowerBound]
        #expect(transcript.ranges(of: "transcriptSaveWorker.submit(").count == 1)
        #expect(transcript.ranges(of: ".write(").isEmpty)
        #expect(transcript.ranges(of: "Data(").isEmpty)
        #expect(transcript.ranges(of: "ISO8601DateFormatter").isEmpty)
    }

    @Test("optional HAL discovery cannot stand in front of route teardown")
    func discoveryHasAnIndependentSerialLane() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        for (start, end, subsystem) in [
            (
                "private func runDeviceControlRefresh(",
                "private func finishDeviceControlRefreshWithoutSnapshot(",
                ".hardwareRead"
            ),
            (
                "func refreshApps()",
                "private func finishAppRefresh(",
                ".applicationInventory"
            ),
            (
                "private func runConfiguredDeviceHydration(",
                "private func finishConfiguredDeviceHydration(",
                ".deviceHydration"
            ),
            (
                "private func runDeviceChangeRefresh(",
                "private func finishDeviceChangeRefresh(",
                ".deviceInventory"
            ),
            (
                "private func refreshPathQualityAsynchronously()",
                "private func poll()",
                ".diagnostics"
            ),
        ] {
            let lower = try #require(model.range(of: start))
            let upper = try #require(
                model.range(of: end, range: lower.upperBound..<model.endIndex))
            let body = model[lower.lowerBound..<upper.lowerBound]
            #expect(body.contains("systemQueryOwners.submit("), Comment(rawValue: start))
            #expect(body.contains("to: \(subsystem)"), Comment(rawValue: start))
            #expect(body.contains("deadline:"), Comment(rawValue: start))
            #expect(!body.contains("systemDiscoveryQueue"), Comment(rawValue: start))
            #expect(!body.contains("engineQueue"), Comment(rawValue: start))
        }

        #expect(model.contains("private final class RouterSystemQueryOwners"))
        #expect(model.contains("BoundedSystemQueryLane<"))
        #expect(!model.contains("systemDiscoveryQueue"))
    }

    @Test("application discovery cannot stand in front of route lifecycle")
    func captureResolutionPrecedesLifecycleAdmission() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let begin = try #require(model.range(of: "private func beginStartOnEngineQueue("))
        let end = try #require(
            model.range(
                of: "/// Finishes a start made obsolete",
                range: begin.upperBound..<model.endIndex))
        let body = model[begin.lowerBound..<end.lowerBound]

        let resolved = try #require(body.range(of: "let runResolvedStart:"))
        let handover = try #require(
            body.range(
                of: "intent.admitEngineLifecycle()",
                range: resolved.upperBound..<body.endIndex))
        let lifecycle = try #require(
            body.range(of: "lifecycleQueue.async", range: handover.upperBound..<body.endIndex))
        let admission = try #require(
            body.range(
                of: "captureResolutionLane.submit(request)",
                range: lifecycle.upperBound..<body.endIndex))

        #expect(handover.lowerBound < lifecycle.lowerBound)
        #expect(lifecycle.lowerBound < admission.lowerBound)
        #expect(body.contains("if selectedApplications.isEmpty"))
        #expect(body.contains("if !captureResolutionLane.submit(request)"))
        #expect(!body.contains("systemDiscoveryQueue"))
        #expect(!body.contains("AudioDevices.defaultOutputUID()"))

        let cancel = try #require(model.range(of: "private func cancelCurrentStart()"))
        let cancelEnd = try #require(
            model.range(
                of: "/// Finishes a start made obsolete",
                range: cancel.upperBound..<model.endIndex))
        let cancellation = model[cancel.lowerBound..<cancelEnd.lowerBound]
        #expect(cancellation.contains("case .finishWithoutEngine:"))
        #expect(cancellation.contains("invalidate(notifying: finish)"))
        #expect(cancellation.contains("case .awaitEngineOwner, .alreadyCancelled:"))
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
            initialisation.contains(
                "if startupPolicy.refreshesDevicesDuringConstruction { refreshDevices() }"
            ))
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
        let serviceGate = try #require(
            launch.range(of: "AppStartup.startsLiveSystemServices"))
        let deviceDiscovery = try #require(
            launch.range(of: "beginInitialDeviceDiscovery()"))
        #expect(serviceGate.lowerBound < deviceDiscovery.lowerBound)
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
        #expect(initialisation.contains("lighting.mode != .off"))

        let restore = try #require(initialisation.range(of: "restore()"))
        let deferred = try #require(
            initialisation.range(of: "refreshPluginsIfNeeded()"))
        #expect(restore.lowerBound < deferred.lowerBound)

        let worker = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PluginRegistryWorker.swift",
            encoding: .utf8)
        #expect(worker.ranges(of: "AudioUnitPlugins.installed").count == 1)
        #expect(worker.contains("LatestExternalWorkLane"))
        #expect(worker.contains("maximumPlugins = 2_048"))
        #expect(worker.contains("defaultTimeout: Duration = .seconds(2)"))

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
                "startsClientImmediately: startupPolicy.startsMIDIImmediatelyDuringConstruction"
            ))

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
        let serviceGate = try #require(
            launch.range(of: "AppStartup.startsLiveSystemServices"))
        let midiStart = try #require(launch.range(of: "beginMIDI()"))
        #expect(serviceGate.lowerBound < midiStart.lowerBound)
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

    @Test("one thousand closed presentations retain zero hosts")
    @MainActor
    func closedPresentationsReleaseTheirHosts() {
        final class Host {}

        var lifetime = TransientPresentationHost<Host>()
        weak var previous: Host?

        for _ in 0..<1_000 {
            autoreleasepool {
                let host = lifetime.acquire { Host() }
                previous = host
                #expect(lifetime.retainedCount == 1)
                lifetime.release()
            }
            #expect(previous == nil)
        }

        #expect(lifetime.generation == 1_000)
        #expect(lifetime.retainedCount == 0)
    }

    @Test("closing the status panel releases the hosting graph")
    func statusPanelCloseReleasesItsHost() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/StatusItem.swift",
            encoding: .utf8)
        let closeStart = try #require(
            source.range(of: "func popoverDidClose("))
        let closeEnd = try #require(
            source.range(
                of: "/// Opens or closes the panel",
                range: closeStart.upperBound..<source.endIndex))
        let close = source[closeStart.lowerBound..<closeEnd.lowerBound]

        #expect(close.ranges(of: "popover.contentViewController = nil").count == 1)
        #expect(close.ranges(of: "panelHost.release()").count == 1)
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

    @Test("panel reopen proves attachment and a live child without requiring a root draw")
    func panelReopenMeasurementUsesObservableWork() throws {
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

        #expect(
            source.contains(
                "\"the menu bar panel still has content when it is opened again\","))
        #expect(source.contains("secondOpen.wasAttached"))
        #expect(source.contains("(openCounts[\"PanelLiveCard\"] ?? 0) > 3"))
        #expect(!source.contains("(openCounts[\"PanelView\"] ?? 0) > 0"))
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

        let worker = try String(
            contentsOfFile: root + "Sources/YunAudioApp/HeadphoneProfileWorker.swift",
            encoding: .utf8)
        #expect(worker.ranges(of: "fileSystem.listDirectory(").count == 1)
        #expect(worker.ranges(of: "fileSystem.readFile(").count == 1)
        #expect(worker.contains("maximumDirectoryEntries = 2_048"))
        #expect(worker.contains("maximumProfileFiles = 256"))
        #expect(worker.contains("maximumProfileBytes = 1 * 1_024 * 1_024"))
        #expect(worker.contains("maximumTotalBytes = 8 * 1_024 * 1_024"))

        let applyStart = try #require(
            model.range(of: "private func applyHeadphoneProfiles("))
        let applyEnd = try #require(
            model.range(
                of: "/// True when a correction is chosen",
                range: applyStart.upperBound..<model.endIndex))
        let apply = model[applyStart.lowerBound..<applyEnd.lowerBound]
        #expect(apply.ranges(of: "FileManager").isEmpty)
        #expect(apply.ranges(of: "contentsOfDirectory").isEmpty)
        #expect(apply.ranges(of: "String(contentsOf").isEmpty)
        #expect(apply.contains("if profilesChanged || !stale.isEmpty"))
    }

}
