import CoreAudio
import Foundation
import Testing

@testable import YunAudioHAL
@testable import YunAudioApp

@Suite("Bluetooth enumeration policy")
struct BluetoothEnumerationPolicyTests {
    @Test("an unrelated classic or LE Bluetooth endpoint skips timing")
    func unrelatedBluetoothSkipsTiming() {
        let selected = Set(["selected"])

        #expect(
            !AudioDevices.shouldLoadDetailedCapabilities(
                transport: .bluetooth, uid: "other-classic", selectedUIDs: selected))
        #expect(
            !AudioDevices.shouldLoadDetailedCapabilities(
                transport: .bluetoothLE, uid: "other-le", selectedUIDs: selected))
    }

    @Test("a selected Bluetooth endpoint loads timing")
    func selectedBluetoothLoadsTiming() {
        #expect(
            AudioDevices.shouldLoadDetailedCapabilities(
                transport: .bluetooth, uid: "selected", selectedUIDs: ["selected"]))
        #expect(
            AudioDevices.shouldLoadDetailedCapabilities(
                transport: .bluetoothLE, uid: "selected", selectedUIDs: ["selected"]))
    }

    @Test("a non-Bluetooth endpoint always loads timing")
    func nonBluetoothLoadsTiming() {
        #expect(
            AudioDevices.shouldLoadDetailedCapabilities(
                transport: .usb, uid: "interface", selectedUIDs: []))
    }

    @Test("an unrelated Bluetooth endpoint reads zero scoped properties")
    func unrelatedBluetoothReadsNoScopedProperties() {
        var topologyScopes: [AudioObjectPropertyScope] = []

        let snapshot = AudioDevice.topologySnapshot(
            loadsDetails: false,
            readsChannelCount: { scope in
                topologyScopes.append(scope)
                return 99
            })

        #expect(topologyScopes.isEmpty)
        #expect(!snapshot.isComplete)
        #expect(snapshot.inputChannels == 0)
        #expect(snapshot.outputChannels == 0)
        #expect(!snapshot.pickerRoleIsCertain)
        #expect(snapshot.pickerRole == [.input, .output])
    }

    @Test("a selected endpoint reads exact topology and no picker guesses")
    func selectedBluetoothReadsExactTopology() {
        var topologyScopes: [AudioObjectPropertyScope] = []

        let snapshot = AudioDevice.topologySnapshot(
            loadsDetails: true,
            readsChannelCount: { scope in
                topologyScopes.append(scope)
                return scope == kAudioObjectPropertyScopeInput ? 1 : 2
            })

        #expect(
            topologyScopes == [
                kAudioObjectPropertyScopeInput,
                kAudioObjectPropertyScopeOutput,
            ])
        #expect(snapshot.isComplete)
        #expect(snapshot.inputChannels == 1)
        #expect(snapshot.outputChannels == 2)
        #expect(snapshot.pickerRoleIsCertain)
        #expect(snapshot.pickerRole == [.input, .output])
    }

    @Test("default input identity performs one ID and one UID metadata read")
    func defaultInputUIDIsMetadataOnly() throws {
        var defaultReads = 0
        var uidReads = 0
        let expectedID = AudioObjectID(73)

        let uid = try AudioDevices.readDefaultDeviceUID(
            readsDefaultID: {
                defaultReads += 1
                return expectedID
            },
            readsUID: { id in
                uidReads += 1
                #expect(id == expectedID)
                return "default-input"
            })

        #expect(uid == "default-input")
        #expect(defaultReads == 1)
        #expect(uidReads == 1)
    }

    @Test("an absent default input does not ask any device for its UID")
    func absentDefaultInputSkipsUIDRead() throws {
        var defaultReads = 0
        var uidReads = 0

        let uid = try AudioDevices.readDefaultDeviceUID(
            readsDefaultID: {
                defaultReads += 1
                return kAudioObjectUnknown
            },
            readsUID: { _ in
                uidReads += 1
                return "must-not-run"
            })

        #expect(uid == nil)
        #expect(defaultReads == 1)
        #expect(uidReads == 0)
    }

    @Test("classic Bluetooth input stays manual while safe transports remain automatic")
    func classicBluetoothInputIsNeverAnAutomaticDefault() {
        #expect(!RouterModel.canSelectInputAutomatically(transport: .bluetooth))
        #expect(!RouterModel.canSelectInputAutomatically(transport: .continuityCapture))
        #expect(RouterModel.canSelectInputAutomatically(transport: .bluetoothLE))
        #expect(RouterModel.canSelectInputAutomatically(transport: .usb))
        #expect(RouterModel.canSelectInputAutomatically(transport: .builtIn))
    }

    @Test("no persisted Bluetooth input may auto-start")
    func persistedBluetoothAlwaysNeedsThisSessionToStartIt() {
        #expect(!RouterModel.canAutoStartPersistedInput(transport: .bluetooth))
        #expect(!RouterModel.canAutoStartPersistedInput(transport: .bluetoothLE))
        #expect(
            !RouterModel.canAutoStartPersistedInput(transport: .continuityCapture))
        #expect(RouterModel.canAutoStartPersistedInput(transport: .usb))
        #expect(RouterModel.canAutoStartPersistedInput(transport: .builtIn))

        #expect(!RouterModel.canProbeRestoredDeviceControls(transport: .bluetooth))
        #expect(!RouterModel.canProbeRestoredDeviceControls(transport: .bluetoothLE))
        #expect(
            !RouterModel.canProbeRestoredDeviceControls(
                transport: .continuityCapture))
        #expect(RouterModel.canProbeRestoredDeviceControls(transport: .usb))
        #expect(RouterModel.canProbeRestoredDeviceControls(transport: .builtIn))
    }

    @Test("metadata-only Bluetooth remains selectable on either side")
    func metadataOnlyBluetoothRemainsSelectableOnEitherSide() {
        let snapshot = AudioDevice.topologySnapshot(
            loadsDetails: false,
            readsChannelCount: { _ in 99 })

        #expect(!snapshot.pickerRoleIsCertain)
        #expect(snapshot.pickerRole == [.input, .output])
        #expect(snapshot.inputChannels == 0)
        #expect(snapshot.outputChannels == 0)
    }

    @Test("enumeration keeps stream configuration behind the topology policy")
    func streamConfigurationHasNoUnconditionalInitialiserRead() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/AudioDevice.swift",
            encoding: .utf8)
        let initialiserStart = try #require(
            source.range(
                of: "init(\n        id: AudioObjectID,\n        loadingBluetoothCapabilitiesFor"
            ))
        let initialiserEnd = try #require(
            source.range(
                of: "    struct TopologySnapshot:",
                range: initialiserStart.upperBound..<source.endIndex))
        let initialiser = source[initialiserStart.lowerBound..<initialiserEnd.lowerBound]

        #expect(!initialiser.contains("inputChannels = Self.channelCount"))
        #expect(!initialiser.contains("outputChannels = Self.channelCount"))
        #expect(initialiser.contains("topologySnapshot("))
        #expect(!initialiser.contains(".canBeDefaultDevice.scoped(to: scope)"))
    }

    @Test("deferred selection keeps the old route and exposes progress or failure")
    func deferredSelectionBoundaryIsVisibleAndNonDestructive() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let sourceStart = try #require(source.range(of: "var selectedSourceUID: String?"))
        let sourceEnd = try #require(
            source.range(
                of: "var selectedDestinationUID: String?",
                range: sourceStart.upperBound..<source.endIndex))
        let observer = source[sourceStart.lowerBound..<sourceEnd.lowerBound]
        let restore = try #require(observer.range(of: "selectedSourceUID = oldValue"))
        let request = try #require(observer.range(of: "requestHydratedSelection("))
        #expect(restore.lowerBound < request.lowerBound)

        let failureStart = try #require(
            source.range(of: "private func reportHydratedSelectionFailure("))
        let failureEnd = try #require(
            source.range(
                of: "private func publishHydratedDevice(",
                range: failureStart.upperBound..<source.endIndex))
        let failure = source[failureStart.lowerBound..<failureEnd.lowerBound]
        #expect(failure.contains("requestedStartAwaitsDeviceHydration = nil"))
        #expect(failure.contains("could not be selected"))
        #expect(source.contains("private(set) var deviceSelectionStatus: String?"))
        #expect(source.contains("Loading %@…"))
    }

    @Test("rapid selection is bounded to first and latest work")
    func rapidSelectionBoundaryIsFirstLatest() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let requestStart = try #require(
            source.range(of: "private func requestHydratedSelection("))
        let requestEnd = try #require(
            source.range(
                of: "private func runHydratedSelection(",
                range: requestStart.upperBound..<source.endIndex))
        let request = source[requestStart.lowerBound..<requestEnd.lowerBound]
        #expect(request.contains("work.latest = pending"))
        #expect(request.ranges(of: "runHydratedSelection(").count == 1)

        let finishStart = try #require(
            source.range(of: "private func finishHydratedSelection("))
        let finishEnd = try #require(
            source.range(
                of: "private func cancelHydratedSelection(",
                range: finishStart.upperBound..<source.endIndex))
        let finish = source[finishStart.lowerBound..<finishEnd.lowerBound]
        #expect(finish.contains("if let latest = work.latest"))
        #expect(finish.contains("work.active = latest"))
        #expect(finish.contains("runHydratedSelection(latest"))
    }

    @Test("structural lint keeps restored topology intent behind policy and Stop")
    func restoredAutomaticStartWaitsForTopology() throws {
        // The transport decisions are executable in
        // `persistedBluetoothAlwaysNeedsThisSessionToStartIt` above. This source
        // lint checks only that RouterModel wires those decisions to hydration
        // and revokes the pending intent at its Stop boundary.
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let requestStart = try #require(
            source.range(of: "private func requestAutomaticStartIfConfigured()"))
        let requestEnd = try #require(
            source.range(
                of: "private var configuredDevicesHaveCompleteTopology",
                range: requestStart.upperBound..<source.endIndex))
        let request = source[requestStart.lowerBound..<requestEnd.lowerBound]
        let manualGuard = try #require(
            request.range(of: "!persistedRouteRequiresManualStart"))
        let topologyGuard = try #require(
            request.range(of: "guard configuredDevicesHaveCompleteTopology else"))
        #expect(manualGuard.lowerBound < topologyGuard.lowerBound)
        #expect(request.contains("automaticStartAwaitsDeviceHydration = true"))
        #expect(
            request.ranges(of: "hydrateConfiguredDevicesAsynchronously()").count == 1)
        #expect(
            source.contains(
                "if automaticStartAwaitsDeviceHydration, configuredDevicesHaveCompleteTopology")
        )

        let stopStart = try #require(source.range(of: "func stop()"))
        let stopEnd = try #require(
            source.range(
                of: "guard !isBusy",
                range: stopStart.upperBound..<source.endIndex))
        let stop = source[stopStart.lowerBound..<stopEnd.lowerBound]
        #expect(stop.contains("requestedStartAwaitsDeviceHydration = nil"))
        #expect(stop.contains("automaticStartAwaitsDeviceHydration = false"))
    }
}
