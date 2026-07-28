import AppKit
import SwiftUI
import YunDesign

/// The menu bar presence, built on AppKit rather than `MenuBarExtra`.
///
/// SwiftUI's `MenuBarExtra` gives no way to handle a right-click, and a menu bar
/// application without one is missing the gesture people reach for first when
/// they want to quit it. Owning the `NSStatusItem` costs a little more code and
/// returns full control: left-click opens the panel, right-click opens a menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()

    private static let panelWidth: CGFloat = 340
    /// Leaves room for the menu bar and a margin on the shortest Mac display
    /// still supported; beyond this the panel scrolls.
    private static let maximumPanelHeight: CGFloat = 680
    private let model: RouterModel
    private var levelObserver: Timer?

    init(model: RouterModel, openMainWindow: @escaping @MainActor () -> Void) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        // The panel is taller than any fixed height worth choosing: it grows
        // with the number of routes, and every disclosure in it expands. Hosted
        // flat at 560 points it was 639 points tall with everything collapsed,
        // so the last section was simply unreachable — and there was nothing to
        // say so, because a popover clips rather than scrolls.
        let host = NSHostingController(
            rootView: ScrollView {
                PanelView(model: model)
            }
            .scrollIndicators(.never)
            .frame(width: Self.panelWidth)
            .frame(maxHeight: Self.maximumPanelHeight)
        )
        // Lets the popover shrink to a short panel instead of always claiming
        // the maximum, while the frame above stops it growing past the screen.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.delegate = self

        if let button = item.button {
            button.image = Self.statusImage(level: nil)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick)
            // Both buttons come to the same action; which one it was is read
            // from the current event.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        // Mute first, because it is the one thing anybody opens this menu in a
        // hurry to do.
        muteItem = menu.addItem(
            withTitle: loc("Mute"), action: #selector(toggleMute), keyEquivalent: "")
        muteItem?.target = self
        menu.addItem(
            withTitle: loc("Start / stop routing"), action: #selector(toggleRouting),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        // Whole-machine arrangements. This is the one place they belong: the
        // moment somebody wants them is when the work changes, and at that
        // moment the application is not on screen — it is a menu bar icon and a
        // half-finished thought about a call starting in a minute.
        configItem = menu.addItem(
            withTitle: loc("Setups"), action: nil, keyEquivalent: "")
        configItem?.submenu = NSMenu()
        menu.addItem(.separator())
        menu.addItem(
            withTitle: loc("Open YunAudio"), action: #selector(openWindow), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: loc("Settings"), action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: loc("Quit"), action: #selector(quit), keyEquivalent: "q"
        ).target = self
        rightClickMenu = menu
        self.openMainWindow = openMainWindow

        // Redraw the glyph as the level moves. Twice a second is enough for a
        // 15-point image and keeps an idle menu bar from waking the CPU.
        levelObserver = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in self.refreshImage() }
        }
    }

    private var rightClickMenu: NSMenu?
    private var muteItem: NSMenuItem?
    private var configItem: NSMenuItem?
    private var openMainWindow: (@MainActor () -> Void)?

    /// What the glyph is showing, in the only detail it can show.
    ///
    /// The mark was rebuilt twice a second forever — an `NSImage`, locked,
    /// drawn into and unlocked — whether or not anything about it had changed.
    /// Idle, nothing about it *can* change: with no route running there is no
    /// level, so the same eighteen points were redrawn a hundred and seventy
    /// thousand times a day to produce the same pixels.
    ///
    /// The level is continuous and the drawing is not: it becomes an alpha on a
    /// four-point dot, and at that size a step of a fortieth is not a step
    /// anybody can see. So the comparison is against what is *drawn* rather
    /// than against the level, or a meter jittering in the noise floor would
    /// redraw as often as before and the whole thing would be a comment.
    struct Mark: Equatable {
        var isMuted: Bool
        var isAlarmed: Bool
        /// Nil when nothing is running, so there is no dot at all.
        var intensity: Int?

        /// Forty steps across the alpha ramp, which is finer than the eye at
        /// eighteen points and coarse enough that a still room is still.
        static func of(level: Float?, isMuted: Bool, isSpeakingWhileMuted: Bool) -> Mark {
            Mark(
                isMuted: isMuted,
                // Only ever alongside a mute: on a live microphone this is a
                // meter, and the mark does not draw meters.
                isAlarmed: isMuted && isSpeakingWhileMuted,
                intensity: level.map { Int((min(1, max(0, $0)) * 40).rounded()) })
        }
    }

    private var drawnMark: Mark?
    /// How many times the glyph has actually been redrawn, for the check that
    /// this is not merely a comment.
    private(set) static var redraws = 0

    private func refreshImage() {
        let level = model.isRunning ? model.peakLevel : nil
        let mark = Mark.of(
            level: level, isMuted: model.isMuted,
            isSpeakingWhileMuted: model.isSpeakingWhileMuted)
        if mark != drawnMark {
            drawnMark = mark
            Self.redraws += 1
            item.button?.image = Self.statusImage(
                level: level, isMuted: model.isMuted,
                isSpeakingWhileMuted: model.isSpeakingWhileMuted)
        }
        // Cheap and it has to stay in step with a mute that arrived from a
        // hotkey or from MIDI rather than from this menu.
        let title = model.isMuted ? loc("Unmute") : loc("Mute")
        if muteItem?.title != title { muteItem?.title = title }
        refreshConfigs()
    }

    /// Rebuilt rather than kept in step, because the list is short and the
    /// alternative is a second copy of it that can disagree with the first.
    private func refreshConfigs() {
        guard let submenu = configItem?.submenu else { return }
        let names = model.quickConfigs.map(\.name)
        guard names != listedConfigs else { return }
        listedConfigs = names
        submenu.removeAllItems()
        if names.isEmpty {
            let empty = submenu.addItem(
                withTitle: loc("Nothing saved yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for name in names {
            let entry = submenu.addItem(
                withTitle: name, action: #selector(applyConfig(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = name
        }
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: loc("Save the current setup"), action: #selector(saveConfig),
            keyEquivalent: ""
        ).target = self
    }

    private var listedConfigs: [String]?

    @objc private func applyConfig(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
            let configuration = model.quickConfigs.first(where: { $0.name == name })
        else { return }
        model.apply(configuration)
    }

    /// Named after what it captures rather than asked for, because a menu is
    /// not a place to type and the moment this is used is a hurried one. The
    /// name can be changed in the window.
    @objc private func saveConfig() {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm"
        model.saveQuickConfig(named: loc("Setup") + " " + stamp.string(from: Date()))
    }

    @objc private func toggleMute() { model.toggleMute() }

    @objc private func toggleRouting() { model.toggle() }

    /// The mark, with a dot beneath it while routing.
    ///
    /// Drawn rather than composed in SwiftUI because a status item takes an
    /// `NSImage`, and rendering a view to one every half second to show a five
    /// pixel dot would be a great deal of machinery for very little.
    /// Internal rather than private so the drawing can be asserted. Three
    /// states that have to look different from one another is exactly the kind
    /// of claim that is obviously true and occasionally false — a badge drawn
    /// one point larger, at eighteen points, can be no difference at all.
    static func statusImage(
        level: Float?, isMuted: Bool = false, isSpeakingWhileMuted: Bool = false
    ) -> NSImage? {
        guard let mark = YunAppIcon.image else { return nil }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        mark.draw(
            in: NSRect(x: 0, y: 3, width: 15, height: 15),
            from: .zero, operation: .sourceOver, fraction: 1)
        if isMuted {
            // Muted outranks the level, and it is drawn whether or not routing
            // is running: talking into a muted microphone is the single most
            // expensive mistake this application can let somebody make, and the
            // menu bar is the only part of it they are looking at.
            //
            // Which is why the mark has two muted states rather than one. The
            // window can say "muted, but talking" all it likes; nobody is
            // looking at the window — they are looking at the call. So when the
            // system's own detector says somebody is speaking into a muted
            // microphone, the badge grows and takes a ring, and that change is
            // visible out of the corner of an eye at eighteen points. A warning
            // nobody sees is not a warning.
            let alarmed = isSpeakingWhileMuted
            NSColor.systemRed.setFill()
            let badge =
                alarmed
                ? NSRect(x: 4.5, y: -0.5, width: 6, height: 6)
                : NSRect(x: 5.5, y: 0, width: 4, height: 4)
            NSBezierPath(ovalIn: badge).fill()
            if alarmed {
                // A ring rather than a bigger dot alone: at this size a dot one
                // point larger is not a difference anybody notices, and the
                // whole value of this is being noticed without being looked at.
                NSColor.systemRed.withAlphaComponent(0.55).setStroke()
                let ring = NSBezierPath(ovalIn: badge.insetBy(dx: -2, dy: -2))
                ring.lineWidth = 1
                ring.stroke()
            }
            // A bar across it, so it reads as muted rather than as some other
            // kind of red — the shape has to survive being four pixels wide.
            NSColor.systemRed.setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3.5, y: 0))
            slash.line(to: NSPoint(x: 11.5, y: 5))
            slash.lineWidth = 1.5
            slash.stroke()
        } else if let level {
            // Scaled so speech, which sits low on a linear scale, still moves it.
            let intensity = CGFloat(min(1, pow(min(1, level * 4), 0.5)))
            NSColor.systemGreen.withAlphaComponent(0.35 + 0.65 * intensity).setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.5, y: 0, width: 4, height: 4)).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)
        {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        guard let menu = rightClickMenu, let button = item.button else { return }
        // Attaching the menu to the item makes AppKit open it on the next click
        // rather than this one, so it is popped up directly and detached again.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func openWindow() {
        popover.performClose(nil)
        openMainWindow?()
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        model.shutDown()
        NSApp.terminate(nil)
    }
}
