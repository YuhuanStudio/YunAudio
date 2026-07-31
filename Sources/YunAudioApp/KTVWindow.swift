import AppKit
import SwiftUI
import YunAudioEngine
import YunDesign

/// Owns the large singing stage without changing the router's three-column window.
///
/// A karaoke view wants distance, large type and an optional full-screen canvas.
/// Those requirements are the opposite of the compact property inspector, so the
/// two presentations share state but not a window or a layout contract.
@MainActor
enum KTVWindow {
    private static var controller: NSWindowController?
    private static var delegate: Delegate?

    static var isVisible: Bool {
        controller?.window?.isVisible == true
    }

    @discardableResult
    static func open(model: RouterModel, fullScreen: Bool = false) -> Bool {
        let controller = controller ?? makeController(model: model)
        self.controller = controller
        if controller.window?.contentView == nil {
            controller.window?.contentView = makeHost(model: model)
        }
        model.isSingingVisible = true
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if fullScreen, controller.window?.styleMask.contains(.fullScreen) == false {
            controller.window?.toggleFullScreen(nil)
        }
        return controller.window?.isVisible == true
    }

    static func toggleFullScreen() {
        controller?.window?.toggleFullScreen(nil)
    }

    /// The stage's own window, for the one thing SwiftUI cannot express: a
    /// scroll wheel. A local event monitor sees every window in the process,
    /// so it has to be able to tell whether an event was meant for this one.
    static var window: NSWindow? { controller?.window }

    private static func makeController(model: RouterModel) -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        let delegate = Delegate(model: model)
        self.delegate = delegate
        window.delegate = delegate
        window.title = loc("KTV")
        WindowChrome.integrate(window)
        // Opaque, and the stage's own colour. A clear background made every
        // region SwiftUI had not yet painted show the desktop instead — which
        // is what the transparent band along the top edge actually was.
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = makeHost(model: model)
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("YunAudioKTVWindow")
        window.center()
        return NSWindowController(window: window)
    }

    /// One construction path keeps a reopened stage identical to its first one.
    ///
    /// The stage is held one level below the content view, autoresized rather
    /// than constrained, so that `safeAreaRegions` can be cleared without the
    /// window coming apart.
    ///
    /// Clearing it is what makes the artwork reach the frame's own top edge. The
    /// thirty-two points measured along that edge are the hosting view's own
    /// safe-area region, and nothing inside SwiftUI reaches them: with the
    /// region left in place `safeAreaInsets` reads zero, so the stage cannot see
    /// what it is being inset by, and `ignoresSafeArea` — on the background, on
    /// its container, anywhere — leaves the strip exactly as it was.
    ///
    /// Clearing it on a hosting view that *is* the content view is what tore the
    /// window: it and `fullSizeContentView` invalidated each other's constraints
    /// every pass, so the window climbed to 1136 points for a 720-point request
    /// and AppKit threw `NSGenericException: more Update Constraints in Window
    /// passes than there are views in the window`. What reached the screen was
    /// whichever partial pass happened to be current — the transparent band and
    /// the cut-off button were that, not a styling choice. One level down and
    /// autoresized, the stage publishes no constraints at all, so there is
    /// nothing left to diverge. The container is black so that anything the
    /// stage has not painted reads as stage rather than as desktop.
    private static func makeHost(model: RouterModel) -> NSView {
        let host = NSHostingView(rootView: KTVStage(model: model))
        host.safeAreaRegions = []
        host.setAccessibilityIdentifier("YunAudioKTVWindow")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        return container
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        private let model: RouterModel

        init(model: RouterModel) {
            self.model = model
        }

        func windowWillClose(_ notification: Notification) {
            (notification.object as? NSWindow)?.contentView = nil
            if model.inspectorTab != .singing {
                model.isSingingVisible = false
            }
        }
    }
}

struct KTVStage: View {
    @Bindable var model: RouterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isRendering = false

    /// Seeds the browsed state for a capture.
    ///
    /// Neither gate can turn a wheel, so the column taken off the song is a
    /// state no image would ever hold — and an interface state with no image
    /// of it is one nobody has looked at. Set by the renderer only; the
    /// running application never assigns it.
    nonisolated(unsafe) static var browsedLineForRendering: Int?

    /// Seeds the word size for a capture, for the same reason and with the
    /// same rule: set by the renderer only. Writing the real setting would
    /// change what somebody had chosen for themselves, which a capture has no
    /// business doing.
    nonisolated(unsafe) static var lyricScaleForRendering: Double?

    /// What the words are drawn at.
    private var lyricScale: Double { Self.lyricScaleForRendering ?? model.lyricScale }

    /// What one line of this song really costs, counted rather than allowed for.
    ///
    /// Measured on the song that is loaded, including the wrapping of the
    /// pronunciation and translation rows, which an allowance could never have
    /// caught: a pronunciation row is three Latin characters to the Chinese
    /// one, so it passes the measure and takes two rows on any line over about
    /// fourteen characters.
    private var lyricBudget: (rowsPerLine: CGFloat, extraRows: CGFloat) {
        model.lyricRowBudget
    }

    /// Height the attribution above the words takes, when there is one.
    ///
    /// A 12-point row and the 20-point gap under it. Drawn, therefore budgeted:
    /// the band above the sung line is otherwise one label taller than its
    /// share, which is invisible until the words are large and then puts the
    /// label off the top of the window.
    private var reservedLyricHeight: CGFloat {
        model.lyricsSourceName == nil ? 0 : 12 * KTVLyricMetrics.rowHeight + 20
    }

    /// Where the column is looking, when that is not where the song is.
    @State private var browse = KTVLyricBrowse(line: KTVStage.browsedLineForRendering)
    @State private var returnToTheSong: Task<Void, Never>?
    @State private var wheel: Any?

    /// The last size the stage's reader was given, for the capture gate to
    /// compare against the window it was measured in.
    ///
    /// The offscreen renderer hands `KTVStage` an explicit size, so it cannot
    /// disagree with itself; the live window puts the same view inside an
    /// `NSHostingView` whose safe-area region has been cleared. Judging the
    /// arrangement from renders alone was therefore structurally blind to a
    /// reader that reports something other than the window — which is what the
    /// live stage looks like it is doing, with every arrangement sunk towards
    /// the bottom of the frame and the top half empty.
    nonisolated(unsafe) static var lastMeasuredStageSize: CGSize = .zero

    /// The column's last reported size and position, so a layout that has not
    /// moved does not report itself again on every pass.
    nonisolated(unsafe) static var lastColumnPlacement = ""
    nonisolated(unsafe) static var lastWordsPlacement = ""
    nonisolated(unsafe) static var lastControlsPlacement = ""
    nonisolated(unsafe) static var lastReaderSize = ""

    var body: some View {
        GeometryReader { proxy in
            // Counted here rather than at the head of `body`: the reader's
            // closure re-evaluates on its own, and a tick outside it reported
            // zero while everything inside was updating once a second.
            let _ = BodyCount.tick("KTVStage")
            let _ = {
                Self.lastMeasuredStageSize = proxy.size
                guard SongArtwork.isProbing else { return }
                // What the reader itself was proposed, on every layout. The
                // ZStack inside it reports 1036 in a 720-point window, and a
                // stack cannot exceed its proposal unless a child demands more
                // — so the first thing to establish is whether the proposal
                // was 720 at that moment or something else entirely.
                let now = "\(Int(proxy.size.width))x\(Int(proxy.size.height))"
                if now != Self.lastReaderSize {
                    Self.lastReaderSize = now
                    SongArtwork.record("reader \(now)")
                }
            }()
            ZStack {
                // Sized by the ZStack rather than by `proxy.size`, which would
                // pin it to whatever the reader was proposed at the time.
                // `makeHost` is what makes that the whole window frame,
                // title-bar row included.
                // Clamped to the reader, because `aspectRatio(.fill)` reports
                // a size *larger* than the proposal in one dimension and
                // `maxHeight: .infinity` does not pull it back. The `ZStack` is
                // as tall as its tallest child, so a portrait cover grew the
                // stack past the window — 1036 points inside 720 — and
                // everything in it was re-centred 180 points lower, taking the
                // track column's bottom out of the frame.
                //
                // Only ever with real artwork: a placeholder is a gradient with
                // no aspect ratio to enforce, which is why every measurement
                // taken before the cover arrived agreed with the layout and
                // every photograph taken after it did not. Found by replacing
                // each child of the stack in turn — the second substitution
                // moved `473@303` to `473@123`, which is centring exactly.
                stageBackground()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if let track = model.nowPlaying {
                    let inset = max(34, proxy.size.height * 0.07)
                    let stageHeight = max(0, proxy.size.height - inset * 2)
                    let arrangement = KTVStageLayout.resolve(
                        width: proxy.size.width, stageHeight: stageHeight)
                    switch arrangement {
                    case .sideBySide:
                        sideBySide(track, in: proxy.size, stageHeight: stageHeight)
                    case .stacked:
                        stacked(track, in: proxy.size, stageHeight: stageHeight)
                    case .wordsOnly:
                        wordsOnly(track, in: proxy.size, stageHeight: stageHeight)
                    }
                } else {
                    emptyStage
                }

                // Overlays rather than a column with a `Spacer`, which is the
                // better structure whether or not it fixes anything: pinned to
                // their corners the controls ask for no height at all, where a
                // spacer has no upper bound.
                //
                // It does not fix it. The column still reports both `496@111`
                // and `473@303` in a 619-point stage, so the unbounded spacer
                // was not what made the stack taller than its window either —
                // the eighth candidate on this fault to be ruled out by
                // measurement rather than by argument.
                Color.clear
                    .overlay(alignment: .topTrailing) {
                        Button {
                            KTVWindow.toggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.26), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc("Full screen"))
                        .accessibilityIdentifier("OpenKTVFullScreen")
                    }
                    .overlay(alignment: .bottomTrailing) { scoreStrip }
                    .padding(.top, WindowChrome.controlClearance)
                    .padding([.horizontal, .bottom], Yun.Space.lg)

                // Last, and over everything including the words: the whole
                // room turns to look at this, and a card sharing the stage
                // with a lyric it is printed on top of is a card nobody can
                // read the numbers on.
                performanceCard
            }
        }
        // Does anything on this stage get a task at all? `SongArtwork` never
        // reaches the first line of its own, and a view that draws but is not
        // considered to have appeared would explain that without any of it
        // being about artwork.
        .task { SongArtwork.record("stage task ran") }
        .onAppear { startWatchingTheWheel() }
        .onDisappear { stopWatchingTheWheel() }
        // Following again the moment the song changes: the lines somebody was
        // reading belong to a song that is no longer playing.
        .onChange(of: model.nowPlaying?.identity) { _, _ in followTheSongAgain() }
        .coordinateSpace(name: "ktv-stage")
        .background(Color.black)
        .clipShape(.rect(cornerRadius: isRendering ? 18 : 0))
        // The stage takes the keys a player is expected to take. Focusable
        // because a view that is not focusable is never offered one, and the
        // effect is off because a focus ring around the whole window is not
        // what anybody wanted from being able to press space.
        .focusable(!isRendering)
        .onKeyPress { press in
            guard let command = KTVKeyCommand.resolve(press.key, modifiers: press.modifiers)
            else { return .ignored }
            // Escape with nothing over the stage is not ours: full screen is
            // left for the window to leave, which is what the key does there.
            if command == .dismiss, model.lastPerformance == nil { return .ignored }
            perform(command)
            return .handled
        }
        .focusEffectDisabled()
        .accessibilityIdentifier("YunAudioKTVWindow")
    }

    private static let isOffscreenRender =
        ProcessInfo.processInfo.environment["YUNAUDIO_RENDER"] != nil

    /// Carries out what a key asked for.
    private func perform(_ command: KTVKeyCommand) {
        switch command {
        case .playPause: model.sendTransport(.playPause)
        case .skip(let seconds): model.skipNowPlaying(by: seconds)
        case .nudgeLyrics(let seconds): model.nudgeLyricOffset(by: seconds)
        case .toggleFullScreen: KTVWindow.toggleFullScreen()
        case .dismiss: model.dismissPerformance()
        case .resizeLyrics(let step):
            if step == 0 { model.resetLyricScale() } else { model.nudgeLyricScale(by: step) }
        case .browse(let lines):
            guard let lyrics = model.lyrics, lyrics.lines.count > 1 else { return }
            browse.step(by: lines, playing: model.lyricLine, lineCount: lyrics.lines.count)
            startTheWayBack()
        }
    }

    /// The stage with nothing on it: what shows before a cover arrives.
    private var emptyStageGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.082, green: 0.082, blue: 0.102),
                Color(red: 0.020, green: 0.020, blue: 0.024),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    @ViewBuilder
    private func stageBackground() -> some View {
        if let track = model.nowPlaying {
            let picture =
                SongArtwork(url: track.artworkURL, title: track.title, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 52)
            // The drift is the single most expensive thing on this stage —
            // more than the words, the meters and the artwork together — and
            // only because SwiftUI resamples the whole window every frame of
            // it. On the render server it is a transform on a picture drawn
            // once. See `CompositedStageBackdrop` for the measurements.
            //
            // `ImageRenderer` cannot rasterise an `NSViewRepresentable`; it
            // draws a yellow prohibition sign instead. The offscreen gate
            // takes the SwiftUI branch so that its images still mean
            // something about colour and layout.
            if Self.isOffscreenRender {
                picture.scaleEffect(CompositedStageBackdrop.scale.from)
            } else {
                // The gradient underneath, not the picture: while the cover is
                // still arriving — or for a song that has none — the layer has
                // no contents, and something has to be behind it. Drawing the
                // SwiftUI blur under it as well would pay for the picture
                // twice.
                emptyStageGradient
                    .overlay {
                        CompositedStageBackdrop(
                            url: track.artworkURL, isMoving: !reduceMotion)
                    }
            }
        } else {
            emptyStageGradient
        }
        // Judged against a real cover for the first time. At 0.58 a bright
        // sleeve — a face in daylight, which is most of them — came through
        // hard enough that the words sat on top of it and stopped being
        // legible. The placeholder gradient this was tuned against could never
        // have shown that.
        Color.black.opacity(0.74)
        LinearGradient(
            colors: [
                .black.opacity(0.20),
                .black.opacity(0.02),
                .black.opacity(0.48),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        // And darker still where the words are. The lyric column occupies the
        // right of every arrangement that has one, so the side that has to
        // carry text gets the weight rather than the whole frame being dimmed
        // to the level its worst corner needs.
        LinearGradient(
            colors: [.black.opacity(0.0), .black.opacity(0.34)],
            startPoint: .leading,
            endPoint: .trailing)
    }

    // MARK: Arrangements

    /// The stage as it has been: the tile and its metadata beside the words.
    @ViewBuilder
    private func sideBySide(
        _ track: NowPlaying.Track, in size: CGSize, stageHeight: CGFloat
    ) -> some View {
        let columnWidth = min(360, max(220, size.width * 0.31))
        HStack(alignment: .center, spacing: max(36, size.width * 0.055)) {
            trackColumn(
                track, width: columnWidth,
                artwork: Self.artworkSide(
                    columnWidth: columnWidth, stageHeight: stageHeight))
                // What the column actually comes out as, against the stage it
                // has. Adjusting the metadata constant by eye is what put the
                // transport row outside the window twice; this reports the
                // number instead.
                .background {
                    GeometryReader { column in
                        // Every layout, not the first one. `onAppear` fires
                        // once, so six rounds of measurement described a stage
                        // whose lyrics and cover had not arrived and never
                        // reported it again — a stage laid out correctly once,
                        // read as a stage laid out correctly. Evaluating a
                        // closure in the reader's body runs whenever the
                        // geometry is recomputed, which is the question.
                        let _ = {
                            guard SongArtwork.isProbing else { return }
                            let frame = column.frame(in: .named("ktv-stage"))
                            let now = "\(Int(column.size.height))@\(Int(frame.minY))"
                            if now != Self.lastColumnPlacement {
                                Self.lastColumnPlacement = now
                                SongArtwork.record("column \(now) in stage \(Int(stageHeight))")
                            }
                        }()
                        Color.clear.onAppear {
                            // Where, as well as how big. Four rounds measured
                            // the column's size — 496 in a 619-point stage,
                            // which fits — and concluded the photograph showing
                            // it clipped must be a timing artefact. It is not:
                            // an extra 400 ms of real suspension changed
                            // nothing. The size was never the question.
                            // Relative to the stage, which is named for the
                            // purpose. `.global` gave -88, a number in a space
                            // whose origin was never established — and a
                            // measurement whose frame of reference is unknown
                            // is not a measurement.
                            let frame = column.frame(in: .named("ktv-stage"))
                            SongArtwork.record(
                                "column \(Int(column.size.height)) at"
                                    + " y=\(Int(frame.minY)) in stage"
                                    + " \(Int(stageHeight))")
                        }
                    }
                }
                // `maxHeight`, not a fixed height with an alignment. Given an
                // exact height the column was placed 302 points down a
                // 619-point stage where centring predicts 92 — the fixed frame
                // was being satisfied by the row rather than positioning the
                // column inside it. Filling the row and centring within it is
                // the arrangement that actually holds.
                .frame(maxHeight: .infinity, alignment: .center)
            // A fixed height, not a maximum. A stack whose own minimum exceeds
            // the proposal is laid out at that minimum and overflows, and
            // `maxHeight` does not stop it: six lyric lines, of which the
            // wrapped ones are two rows each, grew the row past the window and
            // the track column went down with it until its progress bar and the
            // score strip were outside the frame. Clipping belongs inside the
            // column, where the current line stays centred, rather than at the
            // bottom edge of the window.
            let available = max(
                120,
                size.width - columnWidth - max(36, size.width * 0.055)
                    - 2 * max(32, size.width * 0.055))
            lyricsColumn(
                KTVLyricMetrics.resolve(
                    width: available, height: stageHeight, scale: lyricScale, extraRowsPerLine: lyricBudget.extraRows,
                    rowsPerLine: lyricBudget.rowsPerLine,
                    reservedHeight: reservedLyricHeight)
            )
            .frame(maxWidth: .infinity)
            .frame(height: stageHeight)
            .clipped()
            .background {
                GeometryReader { words in
                    // Every layout, for the reason the column reports on every
                    // layout: the row's height is the larger of its two
                    // columns, and if this one grows once the words arrive it
                    // is what pushes the other down.
                    let _ = {
                        guard SongArtwork.isProbing else { return }
                        let frame = words.frame(in: .named("ktv-stage"))
                        let now = "\(Int(words.size.height))@\(Int(frame.minY))"
                        if now != Self.lastWordsPlacement {
                            Self.lastWordsPlacement = now
                            SongArtwork.record("words \(now)")
                        }
                    }()
                    Color.clear
                }
            }
        }
        .padding(.horizontal, max(32, size.width * 0.055))
        .padding(.vertical, max(34, size.height * 0.07))
    }

    /// Narrow: the song across the top, the words underneath, both full width.
    ///
    /// A square tile beside the words leaves nothing for the words — at 700
    /// points the lyric column comes out 364 wide, which wraps every line of a
    /// Chinese lyric into three. The tile lies down instead.
    @ViewBuilder
    private func stacked(
        _ track: NowPlaying.Track, in size: CGSize, stageHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.xl) {
            nowPlayingStrip(track, tile: 128, showsProgress: true)
            let band = max(0, stageHeight - 128 - Yun.Space.xl)
            lyricsColumn(
                KTVLyricMetrics.resolve(
                    width: max(120, size.width - 2 * max(32, size.width * 0.055)),
                    height: band, scale: lyricScale, extraRowsPerLine: lyricBudget.extraRows,
                    rowsPerLine: lyricBudget.rowsPerLine,
                    reservedHeight: reservedLyricHeight)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: band)
            .clipped()
        }
        .padding(.horizontal, max(32, size.width * 0.055))
        .padding(.vertical, max(34, size.height * 0.07))
    }

    /// Short: the words, and the least the song can be said in.
    ///
    /// Below about 360 points of stage there is no height for a tile worth
    /// looking at *and* the block beneath it. Rather than shrink the artwork to
    /// a stamp and keep an arrangement built around it, the words take the
    /// stage and the song becomes one line along the bottom.
    @ViewBuilder
    private func wordsOnly(
        _ track: NowPlaying.Track, in size: CGSize, stageHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            // Floored, not merely clamped at zero: a stage of 60 points gave
            // the words nothing and drew a window with nothing in it at all.
            // Below this the column overflows its band and is clipped, which
            // shows some of the words rather than none of them.
            let band = max(72, stageHeight - 62)
            lyricsColumn(
                KTVLyricMetrics.resolve(
                    width: max(120, size.width - 2 * max(32, size.width * 0.055)),
                    height: band, scale: lyricScale, extraRowsPerLine: lyricBudget.extraRows,
                    rowsPerLine: lyricBudget.rowsPerLine,
                    reservedHeight: reservedLyricHeight)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: band)
            .clipped()
            nowPlayingStrip(track, tile: 44, showsProgress: false)
        }
        .padding(.horizontal, max(32, size.width * 0.055))
        .padding(.vertical, max(24, size.height * 0.05))
    }

    /// The song on one line: tile, title, artist, and optionally its progress.
    private func nowPlayingStrip(
        _ track: NowPlaying.Track, tile: CGFloat, showsProgress: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: Yun.Space.lg) {
            SongArtwork(url: track.artworkURL, title: track.title, contentMode: .fit)
                .frame(width: tile, height: tile)
                .background(.black.opacity(0.32))
                .clipShape(.rect(cornerRadius: tile > 80 ? 12 : 8))
                .overlay(
                    RoundedRectangle(cornerRadius: tile > 80 ? 12 : 8)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: showsProgress ? 6 : 2) {
                // Truncating, and told so. `lineLimit(1)` alone still reports
                // the full width as ideal, so a long title — 「線 (《因為遇見你》
                // 電視劇片頭曲)」 — made the column wider than the window and
                // pushed the track's own duration off the right-hand edge.
                Text(track.title)
                    .font(.system(size: tile > 80 ? 20 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(track.artist)
                    .font(.system(size: tile > 80 ? 15 : 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsProgress { progress(track) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: tile)
    }

    /// Nudges the words against the music, and says where they are.
    ///
    /// Shown whenever there are words, not only once something is wrong: a
    /// correction nobody can find is a correction nobody makes, and the reading
    /// is what stops a shifted song being silently shifted for ever. At rest it
    /// says nothing but its two arrows.
    @ViewBuilder
    private var lyricAlignment: some View {
        if model.lyrics != nil {
            let offset = model.lyricOffsetSeconds
            HStack(spacing: Yun.Space.sm) {
                Button {
                    model.nudgeLyricOffset(by: -0.5)
                } label: {
                    Image(systemName: "arrow.left.to.line")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Hold the words back"))
                .accessibilityIdentifier("KTVLyricsEarlier")

                // Only once it is not zero, so the row is two arrows at rest.
                if abs(offset) >= 0.01 {
                    Button {
                        model.clearLyricOffset()
                    } label: {
                        Text(String(format: "%+.1f s", offset))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Yun.Palette.accent.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                    .help(loc("Put the words back where the file had them"))
                    .accessibilityIdentifier("KTVLyricsOffset")
                }

                Button {
                    model.nudgeLyricOffset(by: 0.5)
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Send the words forward"))
                .accessibilityIdentifier("KTVLyricsLater")

                Button {
                    model.showsRomanisation.toggle()
                } label: {
                    Text(verbatim: "拼")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(
                            model.showsRomanisation
                                ? Yun.Palette.accent : .white.opacity(0.72)
                        )
                        .frame(width: 24, height: 24)
                        .background(
                            .white.opacity(model.showsRomanisation ? 0.18 : 0.10),
                            in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Show pronunciation"))
                .accessibilityIdentifier("KTVRomanisation")

                // Only when another index actually answered for this song.
                // A control that does nothing is worse than no control.
                if model.lyricAlternatives.count > 1 {
                    Button {
                        model.useNextLyricSource()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Try another lyric source"))
                    .accessibilityIdentifier("KTVNextLyricSource")
                }
            }
        }
    }

    /// One candidate for the row under the progress bar.
    ///
    /// A `Spacer` must not appear in here: it is flexible down to nothing, so
    /// every candidate containing one fits every proposal and `ViewThatFits`
    /// would always take the first.
    private func playerRow(
        _ track: NowPlaying.Track, showsName: Bool, showsAlignment: Bool
    ) -> some View {
        HStack(spacing: Yun.Space.sm) {
            transportControls(track)
            if showsAlignment { lyricAlignment }
            if showsName {
                Text(track.application)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// Previous, play or pause, next — driving the player the stage is showing.
    ///
    /// The glyph here was a picture of the state and nothing else: a stage that
    /// shows what is playing, names the player, sweeps the words and scores the
    /// singing, and then cannot pause. Both scripting dictionaries carry these
    /// three verbs, so the stage can offer them for either player without
    /// knowing which one it has.
    @ViewBuilder
    private func transportControls(_ track: NowPlaying.Track) -> some View {
        HStack(spacing: Yun.Space.sm) {
            transportButton(
                "backward.fill", label: loc("Previous track"), size: 26,
                identifier: "KTVPreviousTrack"
            ) { model.sendTransport(.previous) }
            transportButton(
                track.isPlaying ? "pause.fill" : "play.fill",
                label: track.isPlaying ? loc("Pause") : loc("Play"), size: 32,
                identifier: "KTVPlayPause"
            ) { model.sendTransport(.playPause) }
            transportButton(
                "forward.fill", label: loc("Next track"), size: 26,
                identifier: "KTVNextTrack"
            ) { model.sendTransport(.next) }
        }
    }

    private func transportButton(
        _ symbol: String, label: String, size: CGFloat, identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.white.opacity(size > 30 ? 0.16 : 0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Side of the artwork tile, bounded by the stage's height as well as by its
    /// width.
    ///
    /// The tile used to be sized from the window's width alone. On a wide, short
    /// stage the 360-point ceiling plus the block beneath it passes the height,
    /// and the column overflows the window exactly as the lyrics did.
    ///
    /// Measured on the 1080×720 stage: from the bottom of the tile to the bottom
    /// of the player row is 138 points with a one-line title. 170 covers a title
    /// that takes two, with the gap above it.
    nonisolated static func artworkSide(
        columnWidth: CGFloat, stageHeight: CGFloat
    ) -> CGFloat {
        max(120, min(columnWidth, stageHeight - KTVStageLayout.metadataHeight))
    }

    private func trackColumn(
        _ track: NowPlaying.Track, width: CGFloat, artwork: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            SongArtwork(url: track.artworkURL, title: track.title, contentMode: .fit)
                .frame(width: artwork, height: artwork)
                .background(.black.opacity(0.32))
                .clipShape(.rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.38), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(track.artist)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            progress(track)

            HStack(spacing: Yun.Space.sm) {
                // The row drops what it cannot hold rather than wrapping it.
                // At 760×900 the column is narrow enough that 「Spotify」 broke
                // across three lines — 「Sp / oti / fy」 — and grew the column
                // while it did it. `ViewThatFits` picks the first candidate
                // whose ideal width fits, so the order here is the order the
                // parts are worth: the transport always, then the alignment
                // controls, then the player's name. No constants to keep in
                // step with the button sizes.
                ViewThatFits(in: .horizontal) {
                    playerRow(track, showsName: true, showsAlignment: true)
                    playerRow(track, showsName: false, showsAlignment: true)
                    playerRow(track, showsName: false, showsAlignment: false)
                }
                Spacer(minLength: 0)
                if let appleMusicURL = track.appleMusicURL {
                    Button {
                        NSWorkspace.shared.open(appleMusicURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Open in Apple Music"))
                }
            }
        }
        .frame(width: width)
    }

    private func progress(_ track: NowPlaying.Track) -> some View {
        KTVSongProgress(model: model, duration: track.duration)
    }
    @ViewBuilder
    private func lyricsColumn(_ metrics: KTVLyricMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lyrics = model.lyrics {
                timedLyrics(lyrics, metrics: metrics)
            } else if let plain = model.plainLyrics {
                Text(plain)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(loc("Looking for lyrics…"))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        // A measure, then centred in what is left. A line of text is read by
        // sweeping back to the start of the next one, and past about
        // twenty-two Chinese characters that sweep is long enough to lose the
        // place — so beyond it the block stops widening. Left-aligned in a
        // column that kept widening, the words sat against the left edge of a
        // wide stage with the right half of it empty.
        .frame(maxWidth: metrics.measure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .clipped()
    }

    /// Six lines with the one being sung anchored at the centre of the column.
    ///
    /// The whole block used to be centred instead, so where the current line
    /// landed depended on how many of the six existed and how many of them
    /// wrapped — it drifted down the stage as the song went on and sat in the
    /// lower third of a large window with the top half empty. Anchoring it
    /// means the eye has one place to be: the lines above grow upwards from the
    /// centre and the lines below grow down from it, which is what every player
    /// that does this well does.
    private func timedLyrics(_ lyrics: Lyrics, metrics: KTVLyricMetrics) -> some View {
        // Two different lines, and the difference is the whole feature: the
        // one the column is centred on, and the one the music is on. They are
        // the same until somebody scrolls, and while they are not, the line
        // being sung keeps its fill wherever it happens to sit.
        let playing = model.lyricLine
        let current = browse.centre(whilePlaying: playing) ?? 0
        // Built from the song, not per line: the same singer keeps one colour
        // for the whole of it, and a song with one voice takes none at all.
        let voices = KTVSingerVoices(lyrics)
        // Whether a count *can* happen — the music is waiting rather than
        // being sung — is a fact about the line, and changes when the line
        // does. How many dots are left is a fact about the second, and is read
        // inside `KTVCountInDots` so that reading it does not rebuild the
        // whole stage once a second. Suppressed while the column is being
        // looked through: a cue is for the line the music is on.
        let countIn =
            !browse.isBrowsing
            && (playing.map { lyrics.lines.indices.contains($0) && lyrics.lines[$0].isInterlude }
                ?? true)
        let behind = Array(metrics.offsets.filter { $0 < 0 })
        let ahead = Array(metrics.offsets.filter { $0 > 0 })
        // Spaced, because the bands do not space themselves. The one above is
        // bottom-aligned and the one below top-aligned — that is what holds
        // the sung line on the centre line — so both are pushed hard against
        // it and every gap in the column existed except the two that matter.
        // With a singer's name above a line it read as part of the line before.
        return VStack(alignment: .leading, spacing: metrics.spacing) {
            // The attribution rides at the bottom of the band above the words
            // rather than at the top of the column. The bands expand to hold
            // the current line on the centre line, so a label placed above them
            // ends up at the top of the whole stage — two thousand points from
            // the thing it is attributing.
            VStack(alignment: .leading, spacing: 20) {
                if let source = model.lyricsSourceName {
                    Text(String(format: loc("Words from %@"), source))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.40))
                }
                lyricGroup(
                    lyrics, current: current, playing: playing, countIn: countIn, voices: voices,
                    offsets: behind, metrics: metrics, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            lyricGroup(
                lyrics, current: current, playing: playing, countIn: countIn, voices: voices,
                offsets: [0], metrics: metrics, alignment: .leading)
            lyricGroup(
                lyrics, current: current, playing: playing, countIn: countIn, voices: voices,
                offsets: ahead, metrics: metrics, alignment: .topLeading)
        }
        .overlay(alignment: .bottomTrailing) { returnToTheSongButton }
    }

    /// The way back, shown only when the column has been taken off the song.
    @ViewBuilder
    private var returnToTheSongButton: some View {
        if browse.isBrowsing {
            Button {
                followTheSongAgain()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                    Text(loc("Back to the line being sung"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(.black.opacity(0.42), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("KTVFollowTheSong")
            .transition(.opacity)
        }
    }

    /// Watches the wheel over the stage's window.
    ///
    /// A local monitor rather than a `ScrollView`: the column's three bands
    /// exist to hold the line being sung on the centre line whatever the six
    /// around it contain, and a scroll view would take that layout back. The
    /// monitor also costs nothing when nobody scrolls, where a scroll view
    /// would have every line of the song in its content.
    private func startWatchingTheWheel() {
        guard !isRendering, wheel == nil else { return }
        wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = KTVWindow.window, event.window === window,
                let lyrics = model.lyrics, lyrics.lines.count > 1
            else { return event }
            browse.scroll(
                by: event.scrollingDeltaY, playing: model.lyricLine,
                lineCount: lyrics.lines.count)
            if browse.isBrowsing { startTheWayBack() }
            // Swallowed: there is nothing else on this stage to scroll, and
            // letting it through means the window server hands it to whatever
            // is underneath.
            return nil
        }
    }

    private func stopWatchingTheWheel() {
        if let wheel { NSEvent.removeMonitor(wheel) }
        wheel = nil
        returnToTheSong?.cancel()
        returnToTheSong = nil
    }

    /// Returns to the song after a while, unless somebody scrolls again.
    ///
    /// A singer who looked ahead and then started singing should not have to
    /// find their place again; somebody reading the last verse should not be
    /// dragged away mid-sentence. Six seconds is the compromise, restarted on
    /// every event.
    private func startTheWayBack() {
        returnToTheSong?.cancel()
        returnToTheSong = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            followTheSongAgain()
        }
    }

    private func followTheSongAgain() {
        returnToTheSong?.cancel()
        returnToTheSong = nil
        guard browse.isBrowsing else { return }
        browse.stop()
    }

    /// One band of the column: the lines behind, the line being sung, or the
    /// lines ahead. The first and last expand to fill what is left, so the
    /// middle one stays on the centre line whatever they contain.
    @ViewBuilder
    private func lyricGroup(
        _ lyrics: Lyrics, current: Int, playing: Int?, countIn: Bool,
        voices: KTVSingerVoices, offsets: [Int],
        metrics: KTVLyricMetrics, alignment: Alignment
    ) -> some View {
        // Identified by the line, not by the slot it occupies. With the offset
        // as the identity, advancing a line makes each slot "the same view with
        // different words", and `contentTransition(.opacity)` cross-fades them
        // in place — the outgoing song's line and the incoming one drawn on top
        // of each other, which is what 「是不是太过清醒背影」 was. Identified by
        // the line, a slot's contents never change: lines arrive and leave.
        let band = VStack(alignment: .leading, spacing: metrics.spacing) {
            ForEach(offsets, id: \.self) { offset in
                let index = current + offset
                if lyrics.lines.indices.contains(index) {
                    let line = lyrics.lines[index]
                    let voice = voices.colour(for: line.singer)
                    VStack(alignment: .leading, spacing: 6) {
                        // Only where it changes hands. A duet names the singer
                        // on every line it owns, and repeating that above each
                        // one turns the stage into a cast list.
                        let previousSinger =
                            lyrics.lines.indices.contains(index - 1)
                            ? lyrics.lines[index - 1].singer : nil
                        if let singer = line.singer, singer != previousSinger {
                            Text(singer)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(
                                    (voice ?? Yun.Palette.accent).opacity(
                                        offset == 0 ? 0.95 : 0.5)
                                )
                                .textCase(nil)
                        }
                        // A rest goes through the same compositor as a line,
                        // so it sweeps as the music crosses it and costs the
                        // stage no ten-hertz read. `CompositedLyricFillTests`
                        // and `BackgroundResourceTests` both assert this file
                        // never reads `lyricProgress`, which is what a hand-rolled
                        // set of filling dots needed and what the compositor
                        // exists to avoid.
                        // The count sits where the eye already is: instead of
                        // the rest's three notes during a break, and above the
                        // first line during an intro. Both are the centre row,
                        // so neither moves anything else on the stage.
                        if offset == 0, countIn {
                            KTVCountInDots(model: model, size: metrics.currentSize)
                        }
                        if !(offset == 0 && countIn && line.isInterlude) {
                            lyricLine(
                                line.isInterlude ? Self.interludeMark : line.text,
                                offset: offset, isPlaying: index == playing,
                                voice: voice, metrics: metrics)
                        }
                        // Pronunciation, above the translation and below the
                        // words: the order a singer reads them in. Only for the
                        // line being sung and the one after it — further away
                        // it is a wall of Latin nobody is looking at, and the
                        // transform is not free.
                        if model.showsRomanisation, abs(offset) <= 1,
                            !line.isInterlude,
                            let latin = LyricRomanisation.of(line.text)
                        {
                            let size = metrics.neighbourSize * KTVLyricMetrics.romanisationScale
                            Text(latin)
                                .font(.system(size: size, weight: .medium))
                                // Split evenly rather than left with a word on
                                // its own. A no-op for a row that already fits,
                                // which on real songs is every pronunciation row.
                                .frame(
                                    maxWidth: metrics.balancedWidth(
                                        for: latin, pointSize: size),
                                    alignment: .leading)
                                .foregroundStyle(
                                    Yun.Palette.accent.opacity(offset == 0 ? 0.78 : 0.42)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Under the line it belongs to, smaller and quieter, so
                        // it reads as the same sentence again rather than as
                        // the next one. Only where the index actually carried
                        // one — most do not, and a blank row under every line
                        // would halve the stage for nothing.
                        if let translation = line.translation {
                            let size = metrics.neighbourSize * KTVLyricMetrics.translationScale
                            Text(translation)
                                .font(.system(size: size, weight: .medium))
                                .frame(
                                    maxWidth: metrics.balancedWidth(
                                        for: translation, pointSize: size),
                                    alignment: .leading)
                                .foregroundStyle(
                                    .white.opacity(
                                        offset == 0 ? 0.68 : Self.lyricOpacity(for: offset) * 0.7)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .id(index)
                    // The words are an index of the song; this is what makes
                    // it one you can use, and what says so before it is tried.
                    .seekableLine {
                        model.seekToLyricLine(index)
                        followTheSongAgain()
                    }
                }
            }
        }
        return
            band
            .frame(maxWidth: .infinity, alignment: .leading)
            // The band being sung takes only the height it needs; the two
            // around it take everything left, half each, which is what holds
            // the middle one on the centre line.
            .frame(
                maxHeight: alignment == .leading ? nil : .infinity,
                alignment: alignment
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.32), value: model.lyricLine)
    }

    @ViewBuilder
    private func lyricLine(
        _ text: String, offset: Int, isPlaying: Bool, voice: Color?,
        metrics: KTVLyricMetrics
    ) -> some View {
        // The fill belongs to the line the music is on, wherever the column
        // has been scrolled to. Drawing it on the middle row regardless would
        // make browsing look like the song had jumped.
        if isPlaying {
            let size = offset == 0 ? metrics.currentSize : metrics.neighbourSize
            CompositedLyricSurface(model: model, text: text, style: .stage(size), voice: voice)
                .contentTransition(.opacity)
        } else if offset == 0 {
            // Centred but not being sung: prominent, and plainly not the one
            // the music is on.
            Text(text)
                .font(.system(size: metrics.currentSize, weight: .semibold))
                .foregroundStyle((voice ?? .white).opacity(0.62))
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: metrics.neighbourSize, weight: .semibold))
                // The lines ahead carry the colour too: the whole point is
                // seeing which of the next four are yours before they arrive.
                .foregroundStyle((voice ?? .white).opacity(Self.lyricOpacity(for: offset)))
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
                .blur(radius: abs(offset) == 2 ? 1.2 : 0)
        }
    }

    /// What the song that just finished came to.
    ///
    /// Shown over the stage rather than beside it: this is the one moment in a
    /// KTV evening when everybody looks at the screen for a reason that is not
    /// the words, and a card in a corner is a card nobody turns round for.
    ///
    /// It goes on Escape, on the button, or the moment the next song reaches a
    /// line of its own — whichever happens first.
    @ViewBuilder
    private var performanceCard: some View {
        if let performance = model.lastPerformance {
            let card = VStack(alignment: .leading, spacing: Yun.Space.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("How that went"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                    Text(performance.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(performance.artist)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                ForEach(performance.singers) { singer in
                    performanceRow(singer)
                }
                Button {
                    model.dismissPerformance()
                } label: {
                    Text(loc("Done"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("KTVDismissPerformance")
            }
            .padding(Yun.Space.xl)
            .frame(maxWidth: 460)
            .background(.black.opacity(0.86), in: .rect(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
            .accessibilityIdentifier("KTVPerformanceCard")
            ZStack {
                // The stage dimmed rather than the card made opaque: the song
                // is still there behind it, which is the point of a KTV
                // scoreboard, but the numbers are read against a flat field
                // instead of against a lyric line.
                Color.black.opacity(0.62)
                card
            }
        }
    }

    private func performanceRow(_ singer: RouterModel.Singer) -> some View {
        let score = singer.score
        let grade = KTVPerformanceGrade.of(score.percentage)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Yun.Space.sm) {
                Text(singer.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: Yun.Space.sm)
                Text(grade.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Yun.Palette.accent.opacity(0.92))
                Text(String(format: "%.0f%%", score.percentage))
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            if let advice = KTVPerformanceGrade.advice(for: score) {
                Text(advice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }
            // The line that went best, which is the part somebody repeats to
            // the room. A score with no line behind it is a number; this is a
            // moment in the song.
            if let best = KTVPerformanceGrade.bestLine(in: score) {
                Text(
                    String(
                        format: loc("Best line: %@ (%.0f%%)"), best.text, best.percentage)
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var scoreStrip: some View {
        let singers = model.singers
        if !singers.isEmpty {
            HStack(spacing: Yun.Space.md) {
                ForEach(singers.indices, id: \.self) { index in
                    let singer = singers[index]
                    HStack(spacing: 7) {
                        Circle()
                            .fill(index == 0 ? .white : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(singer.name)
                            .lineLimit(1)
                        Text(
                            singer.score.isMeaningful
                                ? String(format: "%.0f%%", singer.score.percentage) : "—"
                        )
                        .fontWeight(.bold)
                        .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.black.opacity(0.30), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var emptyStage: some View {
        VStack(spacing: Yun.Space.md) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
            Text(loc("Play something, or choose the words in the Sing panel."))
                .font(.system(size: 20, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What a rest is drawn as.
    ///
    /// Files mark an intro, an interlude or an outro with a timed line and no
    /// words. Drawn literally that is a gap in the column, which reads as a
    /// layout fault rather than as music — and it is the one moment a singer
    /// most wants a countdown for. Three notes, swept by the same compositor as
    /// the words, say both that it is a rest and how far through it is.
    static let interludeMark = "♪ ♪ ♪"

    private static func lyricOpacity(for offset: Int) -> Double {
        switch offset {
        case -1: 0.30
        case 1: 0.48
        default: 0.16
        }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// A lyric line that can be played from, and that shows it under the pointer.
///
/// Its own view with its own state, deliberately. Hovering is a per-row fact,
/// and holding it on the stage would invalidate the stage — the blurred cover,
/// every other line, the score strip — on every crossing of the pointer, for a
/// change that affects one row's background. This keeps the redraw inside the
/// row it belongs to.
private struct SeekableLine<Content: View>: View {
    let seek: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPointedAt = false

    var body: some View {
        content
            // The row is mostly the space between the glyphs; a hit test
            // against the glyphs alone leaves most of a line dead.
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(isPointedAt ? 0.08 : 0))
                    .padding(.horizontal, -12)
                    .padding(.vertical, -6)
            }
            .onHover { isPointedAt = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isPointedAt)
            .onTapGesture(perform: seek)
            .help(loc("Play from this line"))
    }
}

extension View {
    /// Marks a lyric line as somewhere the song can be played from.
    fileprivate func seekableLine(seek: @escaping () -> Void) -> some View {
        SeekableLine(seek: seek) { self }
    }
}

/// The bar and the two timecodes, which change once a second.
///
/// Its own view for the same reason the compact inspector has one: reading
/// `songSecond` where the stage's own body reads it rebuilt the lyric column,
/// the artwork and the whole track block once a second to move a bar five
/// points tall. The read belongs where the second is drawn.
private struct KTVSongProgress: View {
    @Bindable var model: RouterModel
    let duration: Double

    var body: some View {
        let _ = BodyCount.tick("KTVSongProgress")
        let fraction = duration > 0 ? max(0, min(1, Double(model.songSecond) / duration)) : 0
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(.white.opacity(0.78))
                        .frame(width: geometry.size.width * fraction)
                }
                // The whole bar, not the five points it is drawn as: a target
                // that thin is one nobody hits. Continuous rather than on
                // release, because a lyric stage is scrubbed to find a line and
                // the words have to arrive while the finger is still moving.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard geometry.size.width > 0 else { return }
                            model.seekNowPlaying(
                                toFraction: value.location.x / geometry.size.width)
                        }
                )
                .accessibilityIdentifier("KTVSeek")
            }
            .frame(height: 5)
            .contentShape(Rectangle().inset(by: -10))
            HStack {
                Text(KTVStage.clock(Double(model.songSecond)))
                Spacer()
                Text(duration > 0 ? KTVStage.clock(duration) : "--:--")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
            .monospacedDigit()
        }
    }
}

