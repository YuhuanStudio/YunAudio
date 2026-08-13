import AppKit
import ImageIO
import SwiftUI
import YunDesign

/// Photographs the real window, as the window server draws it.
///
/// `PanelRenderer` builds a view tree offscreen and rasterises it. That is
/// useful for judging colour and spacing, but it is structurally blind to
/// everything the window itself contributes: the title bar and its traffic
/// lights, the title the scene puts there, where the content is clipped when the
/// window is at its minimum size, whether a scroll view actually scrolls. Two
/// defects lived in exactly that blind spot — a title drawn twice, and content
/// bleeding past the footer — and neither could appear in an offscreen capture
/// no matter how carefully it was read.
///
/// So this captures the window's own theme frame instead, which is the view the
/// title bar belongs to. No screen recording permission is involved: the
/// process is drawing its own window into a bitmap it owns.
@MainActor
enum WindowCapture {

    /// Sizes worth photographing. The minimum is where a layout breaks, and it
    /// is the one size an offscreen render will never be asked for, because
    /// offscreen renders are given whatever height makes them look complete.
    private static let sizes: [(name: String, size: CGSize)] = [
        ("min", MainWindowLayout.minimumSize),
        ("tall", CGSize(width: 1180, height: 900)),
    ]

    static func write(to directory: String, model: RouterModel? = nil) async -> Bool {
        // The language these are taken in, stated rather than inherited.
        //
        // `docs/images` is the front page of this project, and the English
        // README's screenshots were English because whoever took them happened
        // to have the application set that way. Retaking them on a machine set
        // to Traditional Chinese silently swapped the language of the
        // documentation — which is a documentation build that cannot be
        // reproduced, and the whole point of these being generated is that
        // anybody can regenerate them.
        if let wanted = ProcessInfo.processInfo.environment["YUNAUDIO_CAPTURE_LANGUAGE"],
            let language = YunLanguage(rawValue: wanted)
        {
            // For this launch only. Assigning `YunTheme.shared.language`
            // writes the choice to the defaults, so taking the English
            // screenshots on a machine set to Chinese left that machine's
            // application in English — a documentation build that changes the
            // settings of whoever ran it.
            YunStrings.useForThisLaunchOnly(language)
            settle(turns: 4)
        }
        guard let window = mainWindow() else {
            FileHandle.standardError.write(Data("no window to photograph\n".utf8))
            return false
        }
        var wroteEverything = true

        // A non-hardware photograph still needs a signal-shaped fixture. The
        // previous gate photographed twenty-four one-point silence bars, so the
        // spectrum could disappear in both appearances and every image still
        // existed. This is the same representative state as the offscreen
        // renderer, applied to the real scene and real window chrome.
        if ProcessInfo.processInfo.environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil {
            model?.prepareForRendering()
            settle(turns: 12)
        }

        // Both looks. Glass can only be judged here — an offscreen rasteriser
        // gives a material no backdrop, so every glass card renders as nothing.
        for style in YunStyle.allCases {
            YunTheme.shared.style = style
            wroteEverything =
                photograph(
                    window, sizes: sizes, into: directory,
                    suffix: style == .flat ? "" : "-glass") && wroteEverything
        }
        YunTheme.shared.style = .flat

        // Error text is hostile layout input: CoreAudio can return a sentence,
        // path or UID much longer than any copy fixture. Photograph it in the
        // real minimum window so a future change cannot move it back into the
        // header and still pass merely because a PNG existed.
        if let model {
            let previousError = model.lastError
            let monitorMessage = String(
                format: loc(
                    "%@ is unavailable for monitoring. Your main mix is still running."),
                loc("The selected output"))
            model.setErrorForWindowCapture(
                [monitorMessage, monitorMessage, monitorMessage, monitorMessage]
                    .joined(separator: " "))
            settle(turns: 12)
            wroteEverything =
                photograph(
                    window, sizes: [("error-message", MainWindowLayout.minimumSize)],
                    into: directory, appearances: [.aqua, .darkAqua]) && wroteEverything
            model.setErrorForWindowCapture(previousError)
            settle(turns: 4)
        }

        // Every tab, because five of the six had never been photographed. The
        // offscreen renderer cycles them by building a fresh view per tab; the
        // live window is built once by the scene, so whatever tab it opened on
        // was the only one anybody ever saw a photograph of — and a tab nobody
        // photographs is a tab where anything can be wrong. It is where the
        // scripting panel turned out to have no tab at all, and where six tabs
        // turned out not to fit across the column.
        //
        // One appearance each rather than two: what these are for is layout —
        // clipping, overflow, a control that does not fit — and the colour
        // question is already answered by the two full passes above.
        if let model {
            // Whatever is really playing, and then its cover.
            //
            // Two faults met here and the second hid the first. `SongArtwork`
            // is two different views — without a URL it draws a gradient and a
            // letter, with one it draws an image that arrives asynchronously —
            // and the wait for that arrival was written for the KTV window and
            // placed just above it, so every photograph of the Sing tab ever
            // taken caught the letter.
            //
            // Adding the wait here was not enough, because the fixture
            // `prepareForRendering` installs is not isolated from the poll: a
            // player running on the machine replaces `nowPlaying` a moment
            // later. Which shutter fell before that happened decided whether a
            // given picture showed the fixture or the room, so one run produced
            // a Sing tab holding the fixture and a stage holding the real song,
            // in the same set. The documentation was half invented and there
            // was no way to tell which half by looking.
            //
            // Settled for deliberately rather than raced: let the poll take
            // over if it is going to, then photograph what is actually there.
            // With nothing playing that is the fixture, which is why the
            // fixture is still worth having.
            try? await Task.sleep(for: .milliseconds(1600))
            if let artwork = model.nowPlaying?.artworkURL {
                _ = await SongArtworkResources.shared.value(for: artwork)
                settle(turns: 12)
            }
            let wasShowing = model.inspectorTab
            for tab in MainWindow.Inspector.allCases {
                let began = Date()
                model.inspectorTab = tab
                settle(turns: 12)
                // A real suspension as well as the spin, and the cover is why.
                //
                // `settle` occupies the main actor while it turns the loop, and
                // the body of a `.task` is MainActor-isolated — so it cannot
                // start until the main actor yields, which spinning never does.
                // This file learned that for the KTV window and put a
                // `Task.sleep` there; the tab pass kept the spin, so the
                // asynchronous image load never ran and every photograph of the
                // Sing tab showed `SongArtwork`'s letter-and-gradient branch
                // instead of a cover. The stage in the same run showed the
                // cover, which is what made the two look like different songs.
                try? await Task.sleep(for: .milliseconds(700))
                wroteEverything =
                    photograph(
                        window,
                        sizes: [("tab-\(tab.rawValue)", MainWindowLayout.minimumSize)],
                        into: directory, appearances: [.darkAqua]) && wroteEverything
                // Timed per tab, because the whole capture went from thirty
                // seconds to four minutes when these were added and "it got
                // slower" is not something anybody can act on.
                let took = Date().timeIntervalSince(began)
                if took > 3 {
                    FileHandle.standardError.write(
                        Data(String(format: "  %@ took %.1fs\n", tab.rawValue, took).utf8))
                }
            }
            model.inspectorTab = wasShowing
        }

        // The ordinary acceptance gate is deliberately non-hardware: opening a
        // window must not reserve a microphone or wake a Continuity device.
        // `--full` omits this flag and owns the hardware checks that follow.
        if ProcessInfo.processInfo.environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil {
            if let model {
                wroteEverything =
                    await photographAuxiliaryWindows(model: model, into: directory)
                    && wroteEverything
            }
            return wroteEverything
        }

        // The state that matters most is the one nothing else can show: meters
        // moving, the status strip carrying real numbers, a mixer with strips
        // in it. Every capture until now was of an idle window, which is the
        // state a user spends the least time looking at.
        guard let model, model.selectedDestination != nil, !model.isRunning,
            model.prepareForAutomatedAudioUse()
        else { return wroteEverything }
        model.start()
        for _ in 0..<80 where !model.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.isRunning else {
            FileHandle.standardError.write(
                Data("could not start routing — no running capture\n".utf8))
            return wroteEverything
        }
        // Long enough for the meters to have something in them.
        try? await Task.sleep(for: .seconds(2))
        model.toggleRecording()
        for _ in 0..<50 where !model.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(2))

        wroteEverything =
            photograph(
                window, sizes: [("running", CGSize(width: 1180, height: 900))],
                into: directory) && wroteEverything

        model.toggleRecording()
        for _ in 0..<50 where model.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let url = model.recordingURL { try? FileManager.default.removeItem(at: url) }
        model.stop()
        return wroteEverything
    }

    /// The two AppKit-owned windows that the main SwiftUI scene cannot show.
    ///
    /// Their title bars were absent from offscreen renders by construction, so
    /// the 32-point empty strip survived while every design image was green.
    private static func photographAuxiliaryWindows(
        model: RouterModel, into directory: String
    ) async -> Bool {
        var wroteEverything = true

        // The menu bar panel, which nothing has ever photographed.
        //
        // It is in the README's own table and the picture there was taken by
        // hand, once, of an interface that has moved on several times since.
        // A popover has a real window; nobody had handed it to the capture.
        if let statusItem = StatusItemController.current {
            statusItem.setPanelOpenForCheck(true)
            try? await Task.sleep(for: .milliseconds(700))
            settle(turns: 12)
            if let panel = statusItem.panelContentForCapture {
                // Its own path rather than `photograph`, which validates that a
                // window carries an integrated title bar — true of every window
                // this application owns and false of a popover, correctly. The
                // check is right; the panel simply is not a window in the sense
                // it means, so what is captured is the content view.
                if let data = capture(view: panel),
                    (try? data.write(
                        to: URL(fileURLWithPath: directory + "/live-panel-dark.png"))) != nil
                {
                    FileHandle.standardError.write(
                        Data("photographed \(directory)/live-panel-dark.png\n".utf8))
                } else {
                    FileHandle.standardError.write(
                        Data("the menu bar panel would not render\n".utf8))
                    wroteEverything = false
                }
            } else {
                FileHandle.standardError.write(
                    Data("the menu bar panel would not open for capture\n".utf8))
            }
            statusItem.setPanelOpenForCheck(false)
            try? await Task.sleep(for: .milliseconds(400))
        }

        guard SettingsWindow.open(model: model),
            let settings = PreferencesWindow.openWindow()
        else {
            FileHandle.standardError.write(Data("could not open Settings for capture\n".utf8))
            return false
        }
        settle(turns: 12)
        wroteEverything =
            photograph(
                settings,
                sizes: [("settings", CGSize(width: 760, height: 560))],
                into: directory, appearances: [.darkAqua]) && wroteEverything

        // Reproduce the user's exact state: Settings is the front auxiliary
        // window when the Dock asks the application to reopen. The callback
        // must consume that request and bring the router forward; merely
        // asserting which closure is installed would miss AppKit choosing
        // Settings afterwards.
        if let delegate = TerminationObserver.current {
            let appKitShouldChoose =
                delegate.applicationShouldHandleReopen(
                    NSApp, hasVisibleWindows: true)
            try? await Task.sleep(for: .milliseconds(400))
            settle(turns: 12)
            // Ordering, not key status. A window is key only while its
            // application is active, and a capture launched from a terminal
            // behind whatever the user is working in need not be — so the old
            // assertion could not hold here whatever the router did, and it was
            // written off as intermittent twice and called a product defect
            // once. Which window is in front is the thing the reopen actually
            // controls, and it holds whether or not anybody is looking.
            let routerIsInFront =
                (mainWindow()?.orderedIndex ?? .max) < settings.orderedIndex
            if appKitShouldChoose || !routerIsInFront {
                FileHandle.standardError.write(
                    Data(
                        "Dock reopen left Settings in front"
                            .appending(
                                " — AppKit fallback \(appKitShouldChoose),"
                                    + " router at \(mainWindow()?.orderedIndex ?? -1),"
                                    + " Settings at \(settings.orderedIndex)\n"
                            ).utf8))
                wroteEverything = false
            }
        } else {
            FileHandle.standardError.write(
                Data("Dock reopen could not reach the application delegate\n".utf8))
            wroteEverything = false
        }
        settings.close()

        // The preceding tab pass drives the compact singing view's disappear
        // hook. Restore the no-audio fixture before photographing its other
        // presentation.
        model.prepareForRendering(refreshesApplications: false)
        // Downloaded before the window opens, and waited for. `SongArtwork` is
        // two different views: without a URL it draws a gradient and a letter,
        // and with one it draws a resizable image that arrives asynchronously.
        // Photographed without waiting, every capture of this stage took the
        // first branch — so the branch a user sees had never been in a picture,
        // and the arrangement was being judged from the one that cannot show
        // what the other gets wrong.
        if let artwork = model.nowPlaying?.artworkURL {
            _ = await SongArtworkResources.shared.value(for: artwork)
            settle(turns: 12)
        }
        guard KTVWindow.open(model: model),
            let ktv = NSApp.windows.first(where: {
                $0.frameAutosaveName == KTVWindow.autosaveName && $0.isVisible
            })
        else {
            FileHandle.standardError.write(Data("could not open KTV for capture\n".utf8))
            return false
        }
        // Three shapes, photographed rather than rendered. `KTVStageLayout` has
        // three arrangements and only the first was ever looked at here, and
        // the offscreen renderer — which is what the other two were judged
        // from — hands the stage an explicit size and so cannot reproduce a
        // reader that disagrees with its window.
        // A real suspension, not a run-loop spin. `settle` occupies the main
        // actor while it turns the loop, and the body of a `.task` is
        // MainActor-isolated — so it cannot start until the main actor yields,
        // which spinning never does. Every `.task` on the KTV stage was
        // therefore waiting for a turn that the harness never gave it, and the
        // stage photographed with no artwork and nothing else that waits to
        // appear having run.
        try? await Task.sleep(for: .milliseconds(600))
        // Shapes the window will actually take, asked for from its own rules
        // rather than written down again. 760 × 900 was neither: narrower than
        // the 820-point minimum the stage was given to stop it opening as a
        // letterbox, and taller than the screen — so the window clamped to
        // 820 × 882 and the capture rejected it for not being what it asked
        // for, every run, on a window behaving correctly.
        //
        // The narrow shape is the minimum, because the narrowest arrangement is
        // the thing this picture exists to show. The height is bounded by the
        // screen for the same reason the width is bounded by the minimum: a
        // request the window server cannot grant is not a test.
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        for (label, size) in [
            ("ktv-window", CGSize(width: 1080, height: 720)),
            (
                "ktv-window-narrow",
                CGSize(
                    width: KTVWindowSize.minimum.width,
                    height: min(900, visibleHeight))
            ),
            ("ktv-window-short", CGSize(width: 1180, height: 420)),
        ] {
            settle(turns: 12)
            // And a real suspension after the resize as well as before the
            // window opens. Resizing re-runs the layout, the artwork's arrival
            // re-runs it again, and a shutter between the two catches a column
            // that has not been placed yet — which is what a photograph showing
            // the transport row outside a window that measures 496 points in a
            // 619-point stage actually is. The probe and the picture disagreed
            // twice, and twice the picture was the one that was wrong.
            try? await Task.sleep(for: .milliseconds(400))
            wroteEverything =
                photograph(
                    ktv, sizes: [(label, size)],
                    into: directory, appearances: [.darkAqua]) && wroteEverything
            // What the stage's own reader thinks it has, against what it has.
            // A stage laid out for a taller box than the window sinks its
            // content past the bottom edge, which is what every live capture
            // of this window shows and no render of it does.
            FileHandle.standardError.write(
                Data("\(label): artwork \(SongArtwork.outcomeSummary)\n".utf8))
            let measured = KTVStage.lastMeasuredStageSize
            let content = ktv.contentView?.frame.size ?? .zero
            if abs(measured.height - content.height) > 1
                || abs(measured.width - content.width) > 1
            {
                FileHandle.standardError.write(
                    Data(
                        "\(label): the stage measured \(Int(measured.width))×\(Int(measured.height))"
                            .appending(
                                " in a content view of \(Int(content.width))×\(Int(content.height))"
                                    + " — not accepted\n"
                            ).utf8))
                wroteEverything = false
            }
        }
        // The stage has to have actually appeared, not merely been drawn.
        // `settle` turns the run loop while holding the main actor, and the
        // body of a `.task` is MainActor-isolated — so for as long as this gate
        // spun instead of suspending, every task on the stage waited for a turn
        // it never got. The photographs were of a stage whose artwork had never
        // been requested and whose lifecycle had never run, and nothing said
        // so: they simply looked like a stage with no cover.
        // And the cover has to have arrived, not merely been asked for. Three
        // consecutive runs report `loaded ×4` with the single `cancelled` being
        // the inspector's copy torn down as this window takes over — so the
        // count is stable enough to assert, and a run that photographs
        // placeholders where covers exist now says so.
        if SongArtwork.taskOutcomes["loaded", default: 0] == 0,
            model.nowPlaying?.artworkURL != nil
        {
            FileHandle.standardError.write(
                Data(
                    "the KTV stage was photographed with no cover loaded"
                        .appending(" — not accepted\n").utf8))
            wroteEverything = false
        }
        if !SongArtwork.taskOutcomes.keys.contains("stage task ran") {
            FileHandle.standardError.write(
                Data(
                    "the KTV stage was photographed without ever appearing"
                        .appending(" — not accepted\n").utf8))
            wroteEverything = false
        }
        ktv.close()
        return wroteEverything
    }

    private static func photograph(
        _ window: NSWindow, sizes: [(name: String, size: CGSize)], into directory: String,
        suffix: String = "", appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    ) -> Bool {
        var wroteEverything = true
        for (label, size) in sizes {
            let opened = window.frame.size
            window.setContentSize(size)
            // Not `layoutSubtreeIfNeeded()`. Laying the subtree out by hand
            // immediately after a resize runs the hosting view's constraint
            // update inside the caller's frame, and when that update decides
            // the window's content-size extrema have changed it posts a fresh
            // needs-update to the window — from inside the pass that is
            // already updating. AppKit throws for that, uncaught, and the
            // gate died at 02:39:56 on 2026-07-31 in exactly that stack:
            // `_postWindowNeedsUpdateConstraints` ← `updateConstraints` ←
            // `updateWindowContentSizeExtremaIfNecessary`.
            //
            // The display cycle lays it out anyway, one turn later, which is
            // what every check below already waits for.
            let resized = window.frame.size
            // Roughly the size it was asked for, and *still* that size several
            // run-loop turns later. Two windows were overriding the safe-area
            // region their hosting view derives from `fullSizeContentView`, and
            // both then grew without converging: KTV reached 1136 points and
            // threw an uncaught `NSGenericException`, Settings reached 1410 —
            // the whole height of the screen — after `setContentSize` had
            // already put it at 560. Neither was noticed here, because the
            // image was simply written at whatever size the window had reached
            // and a settings pane that fills the screen still looks like a
            // settings pane. Hence the three sizes in the failure: what the
            // window opened at, what it accepted, and what it drifted back to.
            //
            // The tolerance is the title-bar row itself, taken from AppKit
            // rather than assumed: `fullSizeContentView` moves those points
            // inside the content, so a window may legitimately need that many
            // more than a naive content request. The main window does, at its
            // 632-point floor. Settings at 1410 for a requested 560 does not.
            settle(turns: 8)
            let settled = window.frame.size
            let titleBar = max(0, window.frame.height - window.contentLayoutRect.height)
            if abs(settled.width - size.width) > titleBar + 1
                || abs(settled.height - size.height) > titleBar + 1
            {
                var message = "\(label) was asked for \(Int(size.width))×\(Int(size.height))"
                message += " and settled at \(Int(settled.width))×\(Int(settled.height))"
                message += " — not accepted"
                message += " [opened \(Int(opened.height))"
                message += ", resized \(Int(resized.height))"
                message += ", min \(Int(window.contentMinSize.height))]\n"
                FileHandle.standardError.write(Data(message.utf8))
                wroteEverything = false
                continue
            }
            if !WindowChrome.isIntegrated(window) {
                let reserved =
                    window.frame.height - (window.contentView?.frame.height ?? 0)
                FileHandle.standardError.write(
                    Data(
                        "\(label) still reserves \(reserved) points above its content"
                            .appending(" — not accepted\n").utf8))
                wroteEverything = false
                continue
            }
            for scheme in appearances {
                let isLight = scheme == .aqua
                let name = "live-\(label)\(suffix)-\(isLight ? "light" : "dark").png"

                // Retried because an appearance change does not always reach
                // the view tree within one settle: the second size came out
                // dark in both passes, which is a capture that looks like a
                // design decision. Cheap to check, so it is checked.
                var png: Data?
                for attempt in 0..<4 {
                    NSApp.appearance = NSAppearance(named: scheme)
                    window.appearance = NSAppearance(named: scheme)
                    settle(turns: settledTurns + attempt * 8)
                    png = capture(window)
                    if let png, matches(png, isLight: isLight) { break }
                    png = nil
                }

                guard let png else {
                    let appearance = isLight ? "light" : "dark"
                    let message =
                        "\(name) never came out in the \(appearance) appearance"
                        + " — not written\n"
                    FileHandle.standardError.write(Data(message.utf8))
                    wroteEverything = false
                    continue
                }
                if ProcessInfo.processInfo.environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil,
                    name == "live-min-light.png", !spectrumHasVisibleShape(png)
                {
                    FileHandle.standardError.write(
                        Data(
                            "live-min-light.png has a finite output reading but no visible spectrum"
                                .appending(" — not accepted\n").utf8))
                    wroteEverything = false
                }
                // Through the renderer's writer, which creates the directory and
                // reports a failure rather than announcing a file it did not
                // write. See `PanelRenderer.write(_:named:to:)`.
                print(
                    PanelRenderer.write(png, named: name, to: directory)
                        .replacingOccurrences(of: "wrote ", with: "photographed "))
            }
        }
        NSApp.appearance = nil
        return wroteEverything
    }

    /// The synthetic non-hardware fixture has a voice-shaped spectrum. Assert
    /// that the real window actually drew it, closing the exact hole where a
    /// finite −52.6 dBFS reading sat above twenty-four one-point bars and the
    /// screenshot gate still passed. A live room can be genuinely silent, so
    /// this is evidence only for the deterministic fixture.
    private static func spectrumHasVisibleShape(_ png: Data) -> Bool {
        guard
            let coloured = PixelProbe.count(
                png,
                where: { red, green, blue in
                    blue > 175 && Int(blue) - Int(red) > 10 && Int(green) - Int(red) > 5
                })
        else { return false }
        // A silent spectrum plus the small application mark cannot approach
        // this. The fixture's curve covers tens of thousands of pixels at the
        // minimum window size.
        return coloured > 4_000
    }

    /// Whether a capture is actually in the appearance it claims.
    ///
    /// The window's background is near-white in one and near-black in the
    /// other, so one pixel well inside the content settles it. Sampled below
    /// the title bar, which is translucent and would answer for neither.
    private static func matches(_ png: Data, isLight: Bool) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        // A point a little way down the left edge: past the title bar, which is
        // translucent and would answer for neither appearance, and inside the
        // window's own background rather than any card.
        guard
            let sampled = PixelProbe.sample(
                image, at: CGPoint(x: 6, y: Double(image.height) - 120))
        else { return false }
        return isLight ? sampled.r > 160 : sampled.r < 96
    }
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "YunAudio" && $0.contentView != nil }
    }

    /// Lets the layout, the appearance change and the window server catch up.
    ///
    /// A capture taken in the same turn as `setContentSize` photographs the old
    /// layout, which is a subtle enough lie to be worse than a failure.
    ///
    /// Long enough for the interface's own animations to finish, too, which
    /// eight turns was not. Eight turns is 160 ms and the lyric column's
    /// transition is 240 — so every photograph of the singing tab caught it two
    /// thirds of the way through a cross-fade, with the outgoing line and the
    /// incoming one printed on top of each other. It is indistinguishable from
    /// a layout fault in the picture, and it cost a full round of chasing one.
    /// The longest thing the interface animates is the stage's staggered line
    /// advance at 550 ms plus 120 of stagger; 40 turns is 800.
    private static let settledTurns = 40

    private static func settle(turns: Int = settledTurns) {
        for _ in 0..<turns {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// A view on its own, for the one surface that is not in a window of ours.
    ///
    /// The menu bar panel lives in a popover. `capture(_ window:)` reaches for
    /// the theme frame — the title bar, the traffic lights, the corner rounding
    /// — and a popover has none of those; what it has is the panel.
    private static func capture(view: NSView) -> Data? {
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func capture(_ window: NSWindow) -> Data? {
        // The theme frame, not the content view: the title bar, its traffic
        // lights and the window's own corner rounding all belong to it, and
        // those are precisely what an offscreen render cannot show.
        guard let frame = window.contentView?.superview else { return nil }
        frame.displayIfNeeded()

        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)

        guard let image = bitmap.cgImage else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
