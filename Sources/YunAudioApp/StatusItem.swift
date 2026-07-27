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
    private var openMainWindow: (@MainActor () -> Void)?

    private func refreshImage() {
        item.button?.image = Self.statusImage(
            level: model.isRunning ? model.peakLevel : nil)
    }

    /// The mark, with a dot beneath it while routing.
    ///
    /// Drawn rather than composed in SwiftUI because a status item takes an
    /// `NSImage`, and rendering a view to one every half second to show a five
    /// pixel dot would be a great deal of machinery for very little.
    private static func statusImage(level: Float?) -> NSImage? {
        guard let mark = YunAppIcon.image else { return nil }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        mark.draw(
            in: NSRect(x: 0, y: 3, width: 15, height: 15),
            from: .zero, operation: .sourceOver, fraction: 1)
        if let level {
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
