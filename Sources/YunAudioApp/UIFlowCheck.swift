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

    static func run() {
        let model = RouterModel()

        print("\nlaunch state")
        check("devices were enumerated", !model.inputDevices.isEmpty)
        check("an input is preselected", model.selectedSourceUID != nil)
        if !model.isDriverInstalled {
            note("the virtual device is not installed, so routing flows are skipped")
            note("the panel should be showing the install card")
            check("the install button is offered", model.canInstallDriver)
            summarise()
            return
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
        waitUntil("the route came up", { model.isRunning }, timeout: 3)
        check("no error was reported", model.lastError == nil)
        check("routes were built", !model.activeRoutes.isEmpty)
        check(
            "a fader exists for every route", model.routeGains.count == model.activeRoutes.count
        )

        waitUntil("levels started arriving", { !model.routeLevels.isEmpty }, timeout: 2)
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
        Thread.sleep(forTimeInterval: 0.4)
        check("audio kept flowing", model.cycleCountForDiagnostics > cyclesBefore)
        check("the route set changed", model.activeRoutes.count != before || before > 0)
        check("still running", model.isRunning)

        print("\napplying a preset while running")
        model.apply(.recording)
        Thread.sleep(forTimeInterval: 1.0)
        check("still running after a preset", model.isRunning)
        check("no error after a preset", model.lastError == nil)
        model.apply(.voiceChat)
        Thread.sleep(forTimeInterval: 1.0)

        print("\nstopping")
        model.stop()
        waitUntil("the route came down", { !model.isRunning }, timeout: 3)
        check("levels were cleared", model.routeLevels.isEmpty)
        check("routes were cleared", model.activeRoutes.isEmpty)

        summarise()
    }

    private static func waitUntil(
        _ description: String, _ condition: () -> Bool, timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
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
