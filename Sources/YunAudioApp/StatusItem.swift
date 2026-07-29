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
    /// The level is continuous and the drawing is not: it becomes the length of
    /// a fourteen-point column, and at that size a step of a fortieth is not a
    /// step anybody can see. So the comparison is against what is *drawn*
    /// rather than against the level, or a meter jittering in the noise floor
    /// would redraw as often as before and the whole thing would be a comment.
    struct Mark: Equatable {
        var isMuted: Bool
        var isAlarmed: Bool
        /// Nil when nothing is running, so there is no meter at all.
        var intensity: Int?
        /// Which half of the alarm's blink is showing. Only ever true while
        /// alarmed, so an idle menu bar still compares equal to itself forever.
        var isDim: Bool

        /// Forty steps across the meter, which is finer than the eye at
        /// eighteen points and coarse enough that a still room is still.
        ///
        /// Quantised on what is *drawn* rather than on the level, which are not
        /// the same thing once the meter is on a decibel scale: a fortieth of
        /// the linear range is a third of the column at the bottom of it and
        /// nothing at all at the top.
        static func of(
            level: Float?, isMuted: Bool, isSpeakingWhileMuted: Bool, isDim: Bool = false
        ) -> Mark {
            let alarmed = isMuted && isSpeakingWhileMuted
            return Mark(
                isMuted: isMuted,
                // Only ever alongside a mute: on a live microphone this is a
                // meter, and the mark does not draw meters.
                isAlarmed: alarmed,
                intensity: level.map { Int((meterIntensity($0) * 40).rounded()) },
                isDim: alarmed && isDim)
        }
    }

    private var drawnMark: Mark?
    /// Alternates every tick so the alarm can blink. Counted rather than timed
    /// so the blink cannot drift away from the redraw that carries it.
    private var tick = 0
    /// How many times the glyph has actually been redrawn, for the check that
    /// this is not merely a comment.
    private(set) static var redraws = 0

    private func refreshImage() {
        tick &+= 1
        let level = model.isRunning ? model.peakLevel : nil
        let mark = Mark.of(
            level: level, isMuted: model.isMuted,
            isSpeakingWhileMuted: model.isSpeakingWhileMuted, isDim: tick % 2 == 1)
        if mark != drawnMark {
            drawnMark = mark
            Self.redraws += 1
            item.button?.image = Self.statusImage(
                level: level, isMuted: model.isMuted,
                isSpeakingWhileMuted: model.isSpeakingWhileMuted, isDim: mark.isDim)
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

    // The glyph's geometry, on the eighteen-point square a status item draws
    // into. Named rather than scattered through the drawing because every one
    // of them was chosen against a measurement, and a number nobody can find
    // again is a number that drifts.
    //
    // The mark stops short of the top and bottom edges: Apple's own menu bar
    // symbols sit inside about sixteen points of the eighteen, and a glyph that
    // touches the edge reads as too large next to them. It sits a point left of
    // centre so that the meter column beside it does not push the pair off
    // balance — and a point, at this size, is not a thing anybody sees.
    private static let canvas = NSSize(width: 18, height: 18)
    private static let markHeight: CGFloat = 14
    private static let markCentre = NSPoint(x: 8, y: 9)
    private static let meter = NSRect(x: 13.3, y: 2, width: 2.1, height: 14)

    /// How full the meter is, from a peak level.
    ///
    /// On a decibel scale, because the meter now says its number by length and
    /// the old curve — `min(1, level × 4)` — reached the top at −12 dBFS. That
    /// is an ordinary speech peak, so the column would have stood full through
    /// every sentence anybody said and told them nothing. It did not matter
    /// when the level was the opacity of a four-point dot; it matters now.
    ///
    /// Floored at −50 dBFS rather than run down to silence, so that a quiet
    /// room reads as an empty meter and does not shuffle the bottom pixel of it
    /// back and forth on the noise floor for as long as the application is
    /// running.
    ///
    /// Nonisolated because it is arithmetic: `Mark.of` is a value type's own
    /// factory and has no business hopping to the main actor to divide two
    /// numbers.
    nonisolated static func meterIntensity(_ level: Float) -> CGFloat {
        let floor: Double = -50
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(min(1, level)))
        return CGFloat(min(1, max(0, (decibels - floor) / -floor)))
    }

    /// The mark, in black and white, with a meter beside it while routing.
    ///
    /// A menu bar is not a place for colour. macOS renders a *template* image
    /// in whatever the menu bar's own foreground is, which is what makes an icon
    /// follow light and dark mode, invert while its menu is open, and stay
    /// legible under a tinted desktop — and the price of that is that only the
    /// alpha channel survives. The previous mark spent colour on everything it
    /// had to say: red for muted, green for level. None of it reached the
    /// screen the way it was drawn, and none of it reached a colour-blind user
    /// at all.
    ///
    /// So every state here is a *shape*:
    ///
    ///   - routing, with a level: a column beside the mark, filled by length
    ///   - muted: a slash cut through the mark, with a gap around it so the bar
    ///     reads as a slash rather than as a scratch
    ///   - muted while speaking: the same glyph, blinking
    ///
    /// The blink is the one that earns its keep. Talking into a muted
    /// microphone is the single most expensive mistake this application can let
    /// somebody make, and the menu bar is the only part of it they are looking
    /// at — they are looking at the call. Peripheral vision is poor at shape
    /// and excellent at movement, so a mark that *moves* is seen without being
    /// looked at, which a second static badge never was.
    ///
    /// Drawn rather than composed in SwiftUI because a status item takes an
    /// `NSImage`, and rendering a view to one every half second would be a
    /// great deal of machinery for very little. Internal rather than private so
    /// the drawing can be asserted: "these two look different" is exactly the
    /// kind of claim that is obviously true and occasionally false — a badge
    /// drawn one point larger, at eighteen points, can be no difference at all.
    static func statusImage(
        level: Float?, isMuted: Bool = false, isSpeakingWhileMuted: Bool = false,
        isDim: Bool = false
    ) -> NSImage? {
        guard YunAppIcon.image != nil else { return nil }
        // A drawing handler rather than `lockFocus`, so AppKit re-renders at
        // whatever backing scale it needs. The old glyph was rasterised once at
        // one point per pixel and then scaled up on every Retina display it has
        // ever run on.
        let image = NSImage(size: canvas, flipped: false) { _ in
            drawStatusMark(
                level: level, isMuted: isMuted, isSpeakingWhileMuted: isSpeakingWhileMuted,
                isDim: isDim)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The drawing itself, into the current context, in an eighteen-point square.
    ///
    /// Separate from `statusImage` so a test can render it into a bitmap of
    /// known size and colour space and count pixels, which is not something an
    /// `NSImage` with a drawing handler will promise.
    static func drawStatusMark(
        level: Float?, isMuted: Bool, isSpeakingWhileMuted: Bool, isDim: Bool
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Everything below composites against what is already in the context —
        // the mark is flattened with `.sourceAtop` and the slash's gap is cut
        // with `.destinationOut`. On the transparent canvas a status item draws
        // into, "what is already there" is the mark and nothing else, which is
        // the whole point. On anything else it is the background, and both
        // operations then apply to that instead: drawn straight onto an opaque
        // sheet, this filled the entire square black. A layer of its own means
        // the drawing means the same thing wherever it is asked for.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        // Alarmed, the whole glyph alternates between full strength and a
        // fraction of it. Far enough apart to catch the eye; not so far that it
        // disappears on the dim half and reads as a menu bar item that has
        // fallen off.
        let alarmed = isMuted && isSpeakingWhileMuted
        let strength: CGFloat = alarmed && isDim ? 0.4 : 1

        let markBox = YunAppIcon.inkBox(height: markHeight, centredAt: markCentre)
        YunAppIcon.draw(inkFitting: markBox)
        // The artwork is a gradient and a template keeps only alpha, so it is
        // flattened here deliberately rather than left for AppKit to do: the
        // states drawn below have to compose against a known ink, not against
        // whatever colours happen to be under them.
        NSColor.black.withAlphaComponent(strength).setFill()
        NSRect(origin: .zero, size: canvas).fill(using: .sourceAtop)

        if isMuted {
            // Muted outranks the level, and it is drawn whether or not routing
            // is running.
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: markBox.minX - 1.1, y: markBox.minY + 0.8))
            slash.line(to: NSPoint(x: markBox.maxX + 1.1, y: markBox.maxY - 0.8))
            slash.lineCapStyle = .round

            // The gap first, then the bar inside it. Without the gap the slash
            // is a scratch across a dark shape and disappears at this size;
            // with it, the mark reads as crossed out the way every muted
            // microphone in the system does.
            context.setBlendMode(.destinationOut)
            NSColor.black.setStroke()
            slash.lineWidth = 3
            slash.stroke()
            context.setBlendMode(.normal)
            NSColor.black.withAlphaComponent(strength).setStroke()
            slash.lineWidth = 1.5
            slash.stroke()
        } else if let level {
            // Length rather than alpha. A meter drawn as a fading dot says
            // nothing in monochrome — a faint dot and a small one are the same
            // pixel — where a column that grows is read at a glance.
            let intensity = meterIntensity(level)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: meter, xRadius: meter.width / 2, yRadius: meter.width / 2)
                .setClip()
            // A track behind it, so a quiet room still says "running" rather
            // than looking like a route that has stopped.
            NSColor.black.withAlphaComponent(0.2).setFill()
            meter.fill()
            NSColor.black.setFill()
            NSRect(
                x: meter.minX, y: meter.minY, width: meter.width,
                // Never shorter than it is wide, or the bottom of the meter is
                // a squashed ellipse rather than the end of a column.
                height: max(meter.width, meter.height * intensity)
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
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
