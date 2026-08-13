import CoreAudio
import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioHAL

@Suite("Device control scheduling")
struct DeviceControlSchedulingTests {
    @Test("one snapshot performs exactly three selected-device reads")
    func snapshotReadCountIsFixed() {
        var gainReads = 0
        var monitorReads = 0
        var volumeReads = 0
        let gain = AudioDevice.HardwareGain(
            scalar: 0.5, decibels: -6, decibelRange: -60...0,
            isSettable: true, element: kAudioObjectPropertyElementMain)

        let snapshot = RouterModel.readDeviceControlSnapshot(
            sourceUID: "microphone",
            destinationUID: "speakers",
            readsHardwareGain: { uid in
                gainReads += 1
                #expect(uid == "microphone")
                return gain
            },
            readsHardwareMonitor: { uid in
                monitorReads += 1
                #expect(uid == "microphone")
                return nil
            },
            readsDestinationVolumeControl: { uid in
                volumeReads += 1
                #expect(uid == "speakers")
                return false
            })

        #expect(gainReads == 1)
        #expect(monitorReads == 1)
        #expect(volumeReads == 1)
        #expect(snapshot.hardwareGain == gain)
        #expect(snapshot.hardwareMonitor == nil)
        #expect(!snapshot.destinationHasVolumeControl)
    }

    @Test("an empty selection performs zero device reads")
    func emptySelectionReadsNothing() {
        var reads = 0
        let snapshot = RouterModel.readDeviceControlSnapshot(
            sourceUID: nil,
            destinationUID: nil,
            readsHardwareGain: { _ in
                reads += 1
                return nil
            },
            readsHardwareMonitor: { _ in
                reads += 1
                return nil
            },
            readsDestinationVolumeControl: { _ in
                reads += 1
                return false
            })

        #expect(reads == 0)
        #expect(snapshot.hardwareGain == nil)
        #expect(snapshot.hardwareMonitor == nil)
        #expect(snapshot.destinationHasVolumeControl)
    }

    @Test("a stale device-control answer cannot publish")
    func staleSnapshotIsRejected() {
        #expect(
            RouterModel.deviceControlSnapshotIsCurrent(
                snapshotSourceUID: "mic-a",
                snapshotDestinationUID: "out-a",
                selectedSourceUID: "mic-a",
                selectedDestinationUID: "out-a"))
        #expect(
            !RouterModel.deviceControlSnapshotIsCurrent(
                snapshotSourceUID: "mic-a",
                snapshotDestinationUID: "out-a",
                selectedSourceUID: "mic-b",
                selectedDestinationUID: "out-a"))
        #expect(
            !RouterModel.deviceControlSnapshotIsCurrent(
                snapshotSourceUID: "mic-a",
                snapshotDestinationUID: "out-a",
                selectedSourceUID: "mic-a",
                selectedDestinationUID: "out-b"))
    }

    @Test("selection and echo defaulting contain no synchronous HAL read")
    func sourceBoundariesStayOffMainActor() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)

        let controlsStart = try #require(source.range(of: "func refreshDeviceControls()"))
        let controlsEnd = try #require(
            source.range(
                of: "/// True when two device UIDs",
                range: controlsStart.upperBound..<source.endIndex))
        let controls = source[controlsStart.lowerBound..<controlsEnd.lowerBound]
        #expect(controls.contains("deviceControlRefreshGate.request()"))
        #expect(controls.contains("deviceControlRefreshGate.finish(token)"))
        #expect(controls.contains("runDeviceControlRefresh"))
        #expect(controls.contains("systemQueryOwners.submit("))
        #expect(controls.contains("to: .hardwareRead"))
        #expect(controls.contains("deadline:"))
        let operation = try #require(controls.range(of: "operation:"))
        let beforeOperation = controls[..<operation.lowerBound]
        #expect(!beforeOperation.contains(".hardwareGain("))
        #expect(!beforeOperation.contains(".playThrough("))
        #expect(!beforeOperation.contains(".hasSettableVolume("))

        let defaultsStart = try #require(source.range(of: "func selectDefaults()"))
        let defaultsEnd = try #require(
            source.range(
                of: "/// Picks a sensible channel mode",
                range: defaultsStart.upperBound..<source.endIndex))
        let defaults = source[defaultsStart.lowerBound..<defaultsEnd.lowerBound]
        #expect(!defaults.contains("AudioDevices."))
        #expect(defaults.contains("cachedDefaultInputUID"))
        #expect(
            defaults.contains("Self.canSelectInputAutomatically(transport: device.transport)"))

        let echoStart = try #require(source.range(of: "var resolvedEchoSpeaker:"))
        let echoEnd = try #require(
            source.range(
                of: "/// What the canceller is doing",
                range: echoStart.upperBound..<source.endIndex))
        let echo = source[echoStart.lowerBound..<echoEnd.lowerBound]
        #expect(echo.contains("cachedDefaultOutputUID"))
        #expect(!echo.contains("AudioDevices."))
    }

    @Test("structural lint wires hardware sliders to bounded writes and Stop invalidation")
    func hardwareWritesStayOffMainActor() throws {
        // Rate-limited first-and-latest execution and invalidation are measured
        // by `rateLimitedInFlightValuePublication` and
        // `latestValueInvalidation` in BackgroundResourceTests. This check is
        // only the production wiring from the sliders to those boundaries.
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)

        let monitorStart = try #require(source.range(of: "var hardwareMonitorScalar: Float"))
        let monitorEnd = try #require(
            source.range(
                of: "var hardwareMonitorLabel: String",
                range: monitorStart.upperBound..<source.endIndex))
        let monitor = source[monitorStart.lowerBound..<monitorEnd.lowerBound]
        #expect(monitor.ranges(of: "latestHardwareMonitorWrite =").count == 1)
        #expect(monitor.ranges(of: "submitHardwareControlBatch()").count == 1)
        #expect(monitor.ranges(of: ".setPlayThrough").isEmpty)

        let gainStart = try #require(source.range(of: "var hardwareGainScalar: Float"))
        let gainEnd = try #require(
            source.range(
                of: "var hardwareGainLabel: String",
                range: gainStart.upperBound..<source.endIndex))
        let gain = source[gainStart.lowerBound..<gainEnd.lowerBound]
        #expect(gain.ranges(of: "latestHardwareGainWrite =").count == 1)
        #expect(gain.ranges(of: "submitHardwareControlBatch()").count == 1)
        #expect(gain.ranges(of: ".setHardwareGain").isEmpty)

        let writerStart = try #require(source.range(of: "writeHardwareControl("))
        let writerEnd = try #require(
            source.range(
                of: "/// True when a window that draws any of them",
                range: writerStart.upperBound..<source.endIndex))
        let writer = source[writerStart.lowerBound..<writerEnd.lowerBound]
        #expect(writer.ranges(of: "elements: request.elements").count == 2)

        let appliersStart = try #require(
            source.range(of: "private let hardwareControlAdmissionQueue"))
        let appliersEnd = try #require(
            source.range(
                of: "/// Builds and installs only the newest output curve",
                range: appliersStart.upperBound..<source.endIndex))
        let appliers = source[appliersStart.lowerBound..<appliersEnd.lowerBound]
        #expect(appliers.ranges(of: "interval: .milliseconds(50)").count == 1)
        #expect(appliers.ranges(of: "to: .hardwareWrite").count == 1)
        #expect(appliers.contains("gain: latestHardwareGainWrite"))
        #expect(appliers.contains("monitor: latestHardwareMonitorWrite"))
        #expect(!appliers.contains("systemDiscoveryQueue"))
        #expect(!appliers.contains("queue: engineQueue"))

        let stopStart = try #require(source.range(of: "func stop()"))
        let stopEnd = try #require(
            source.range(
                of: "func retainFailedTeardown(",
                range: stopStart.upperBound..<source.endIndex))
        let stop = source[stopStart.lowerBound..<stopEnd.lowerBound]
        #expect(stop.ranges(of: "invalidateHardwareControlWrites()").count == 1)
        #expect(stop.ranges(of: "systemQueryOwners.invalidate(.hardwareRead)").count == 1)
    }

    @Test("structural lint wires keyed live controls to Stop and Quit invalidation")
    func liveControlsAreCoalescedBeforeTheEngineQueue() throws {
        // `keyedLatestValuePublication` and `keyedLatestValueInvalidation` in
        // BackgroundResourceTests execute ten thousand submissions and assert
        // the exact four-value bound. This source lint checks only RouterModel's
        // admission and lifecycle calls.
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)

        let helperStart = try #require(
            source.range(of: "private func applyLiveControl("))
        let helperEnd = try #require(
            source.range(
                of: "/// Set while a start or stop is in flight",
                range: helperStart.upperBound..<source.endIndex))
        let helper = source[helperStart.lowerBound..<helperEnd.lowerBound]
        #expect(helper.contains("key: LiveControlKey"))
        #expect(helper.contains("liveControlApplier.submit(work, for: key)"))
        #expect(helper.ranges(of: "engineQueue.async").isEmpty)

        let stopStart = try #require(source.range(of: "func stop()"))
        let stopEnd = try #require(
            source.range(
                of: "func retainFailedTeardown(",
                range: stopStart.upperBound..<source.endIndex))
        let stop = source[stopStart.lowerBound..<stopEnd.lowerBound]
        #expect(stop.ranges(of: "liveControlApplier.invalidate()").count == 1)

        let shutdownStart = try #require(source.range(of: "func shutDown("))
        let shutdownEnd = try #require(
            source.range(
                of: "/// Plain evidence returned after a start",
                range: shutdownStart.upperBound..<source.endIndex))
        let shutdown = source[shutdownStart.lowerBound..<shutdownEnd.lowerBound]
        #expect(shutdown.ranges(of: "liveControlApplier.invalidate()").count == 1)
        #expect(source.ranges(of: "applyLiveControl {").isEmpty)
    }
}
