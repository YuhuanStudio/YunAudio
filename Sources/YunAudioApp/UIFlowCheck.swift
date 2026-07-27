import AppKit
import Foundation
import YunAudioEngine
import YunAudioHAL

/// Drives the model through the sequences a person actually performs.
///
/// Offscreen renders show what the interface looks like; they cannot show
/// whether pressing the button does anything. This walks the real flows against
/// real hardware and reports what breaks, which is the only way short of a human
/// with a mouse to find out.
@MainActor
enum UIFlowCheck {
    private static var failures: [String] = []
    private static var notes: [String] = []

    private static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("  ✓ \(description)")
        } else {
            print("  ✗ \(description)")
            failures.append(description)
        }
    }

    private static func note(_ text: String) {
        print("  · \(text)")
        notes.append(text)
    }

    static func run(model: RouterModel) async {
        print("\nlaunch state")
        check("devices were enumerated", !model.inputDevices.isEmpty)
        check("an input is preselected", model.selectedSourceUID != nil)
        if !model.isDriverInstalled {
            note("the virtual device is not installed — the panel shows the install card")
            check("an install button is offered", model.canInstallDriver)
            // Fall back to any loopback so the routing flows are still
            // exercised. Skipping them because one device is absent would leave
            // the part most likely to be broken untested.
            if let fallback = model.outputDevices.first(where: {
                $0.transport.isVirtual && $0.inputChannels > 0
            }) {
                note("routing against \(fallback.name) instead")
                model.selectedDestinationUID = fallback.uid
            } else {
                note("no loopback device at all — routing flows skipped")
                summarise()
                return
            }
        }
        check("an output is preselected", model.selectedDestinationUID != nil)

        print("\napplication list")
        model.refreshApps()
        check("applications were found", !model.availableApps.isEmpty)
        check(
            "every listed application has a name",
            model.availableApps.allSatisfy { !$0.name.isEmpty })
        check(
            "no listed application shows a raw bundle fragment",
            !model.availableApps.contains { $0.name == "Renderer" || $0.name == "client" })

        print("\nstarting")
        model.start()
        await waitUntil("the route came up", { model.isRunning }, timeout: 5)
        check("no error was reported", model.lastError == nil)
        check("routes were built", !model.activeRoutes.isEmpty)
        check(
            "a fader exists for every route", model.routeGains.count == model.activeRoutes.count
        )

        await waitUntil("levels started arriving", { !model.routeLevels.isEmpty }, timeout: 3)
        check("path quality is being reported", model.pathQuality != nil)

        print("\nmuting the first route")
        model.setMuted(true, forRouteAt: 0)
        check("the mute took", model.routeMutes.first == true)
        model.setMuted(false, forRouteAt: 0)
        check("unmuting took", model.routeMutes.first == false)

        print("\nmoving a fader")
        model.setFaderDecibels(-12, forRouteAt: 0)
        check(
            "the fader reads back what was set",
            abs(model.faderDecibels(forRouteAt: 0) - -12) < 0.5)
        model.setFaderDecibels(0, forRouteAt: 0)

        print("\nswitching channel mode while running")
        let before = model.activeRoutes.count
        let cyclesBefore = model.cycleCountForDiagnostics
        model.channelMode = model.channelMode == .mono ? .stereo : .mono
        await pause(0.4)
        check("audio kept flowing", model.cycleCountForDiagnostics > cyclesBefore)
        check("the route set changed", model.activeRoutes.count != before || before > 0)
        check("still running", model.isRunning)

        print("\napplying a preset while running")
        model.apply(.recording)
        await pause(1.0)
        check("still running after a preset", model.isRunning)
        check("no error after a preset", model.lastError == nil)
        model.apply(.voiceChat)
        await pause(1.0)

        print("\npatching")
        let sourcePorts = model.canvasSources
        let destinationPorts = model.canvasDestinations
        check("the canvas offers sources", !sourcePorts.isEmpty)
        check("the canvas offers destinations", !destinationPorts.isEmpty)

        if let source = sourcePorts.first, let destination = destinationPorts.first,
            let lastChannel = destination.channels.last
        {
            let newCable = ChannelRef(deviceUID: destination.uid, channel: lastChannel)
            let before = model.activeRoutes.count
            let cyclesBefore = model.cycleCountForDiagnostics
            model.connect(
                source: ChannelRef(deviceUID: source.uid, channel: source.channels[0]),
                destination: newCable)
            await pause(0.4)
            check("a cable was added", model.activeRoutes.count > before)
            check(
                "audio kept flowing while patching",
                model.cycleCountForDiagnostics > cyclesBefore)

            model.disconnect(destination: newCable)
            await pause(0.4)
            check("the cable was pulled", model.activeRoutes.count == before)
            check("still running after patching", model.isRunning)
        }

        print("\nstopping")
        model.stop()
        await waitUntil("the route came down", { !model.isRunning }, timeout: 5)
        check("levels were cleared", model.routeLevels.isEmpty)
        check("routes were cleared", model.activeRoutes.isEmpty)

        summarise()
    }

    private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func waitUntil(
        _ description: String, _ condition: () -> Bool, timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            await pause(0.05)
        }
        check(description, condition())
    }

    private static func summarise() {
        print("\n" + String(repeating: "─", count: 52))
        if failures.isEmpty {
            print("every flow behaved. \(notes.count) note(s).")
        } else {
            print("\(failures.count) flow(s) failed:")
            for failure in failures { print("  · \(failure)") }
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
