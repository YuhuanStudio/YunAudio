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

    @Test("selection and defaulting contain no synchronous capability read")
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
        #expect(controls.contains("queue.async"))
        let queue = try #require(controls.range(of: "queue.async"))
        let beforeQueue = controls[..<queue.lowerBound]
        #expect(!beforeQueue.contains(".hardwareGain("))
        #expect(!beforeQueue.contains(".playThrough("))
        #expect(!beforeQueue.contains(".hasSettableVolume("))

        let defaultsStart = try #require(source.range(of: "func selectDefaults()"))
        let defaultsEnd = try #require(
            source.range(
                of: "/// Picks a sensible channel mode",
                range: defaultsStart.upperBound..<source.endIndex))
        let defaults = source[defaultsStart.lowerBound..<defaultsEnd.lowerBound]
        #expect(defaults.contains("AudioDevices.defaultInputUID()"))
        #expect(!defaults.contains("AudioDevices.defaultInput()"))
        #expect(
            defaults.contains("Self.canSelectInputAutomatically(transport: device.transport)"))
    }
}
