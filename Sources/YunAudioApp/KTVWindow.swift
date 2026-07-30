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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Sized by the ZStack rather than by `proxy.size`, which would
                // pin it to whatever the reader was proposed at the time.
                // `makeHost` is what makes that the whole window frame,
                // title-bar row included.
                stageBackground()

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

                VStack {
                    HStack {
                        Spacer()
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
                    Spacer()
                    scoreStrip
                }
                // The artwork owns the title-bar row, so the controls inset
                // themselves from it explicitly: there is no safe area left to
                // do it for them, and at `lg` the full-screen button sat level
                // with the traffic lights and read as clipped by the frame.
                .padding(.top, WindowChrome.controlClearance)
                .padding([.horizontal, .bottom], Yun.Space.lg)
            }
        }
        .background(Color.black)
        .clipShape(.rect(cornerRadius: isRendering ? 18 : 0))
        .focusEffectDisabled()
        .accessibilityIdentifier("YunAudioKTVWindow")
    }

    @ViewBuilder
    private func stageBackground() -> some View {
        if let track = model.nowPlaying {
            let phase = (model.lyricLine ?? 0) % 4
            SongArtwork(url: track.artworkURL, title: track.title, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .scaleEffect(phase.isMultiple(of: 2) ? 1.16 : 1.19)
                .offset(
                    x: phase < 2 ? -8 : 8,
                    y: phase == 0 || phase == 3 ? -5 : 5
                )
                .blur(radius: 52)
                // Moving only when the lyric advances gives the stage life
                // without a permanent display-link or background timer.
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.8),
                    value: phase)
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.082, green: 0.082, blue: 0.102),
                    Color(red: 0.020, green: 0.020, blue: 0.024),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
        Color.black.opacity(0.58)
        LinearGradient(
            colors: [
                .black.opacity(0.20),
                .black.opacity(0.02),
                .black.opacity(0.48),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
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
            // A fixed height, not a maximum. A stack whose own minimum exceeds
            // the proposal is laid out at that minimum and overflows, and
            // `maxHeight` does not stop it: six lyric lines, of which the
            // wrapped ones are two rows each, grew the row past the window and
            // the track column went down with it until its progress bar and the
            // score strip were outside the frame. Clipping belongs inside the
            // column, where the current line stays centred, rather than at the
            // bottom edge of the window.
            lyricsColumn
                .frame(maxWidth: .infinity)
                .frame(height: stageHeight)
                .clipped()
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
            lyricsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: max(0, stageHeight - 128 - Yun.Space.xl))
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
            lyricsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: max(0, stageHeight - 62))
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
                Text(track.title)
                    .font(.system(size: tile > 80 ? 20 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: tile > 80 ? 15 : 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                if showsProgress { progress(track) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: tile)
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
        max(120, min(columnWidth, stageHeight - 170))
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
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(track.application)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
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
        let fraction =
            track.duration > 0
            ? max(0, min(1, Double(model.songSecond) / track.duration))
            : 0
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(.white.opacity(0.78))
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 5)
            HStack {
                Text(Self.clock(Double(model.songSecond)))
                Spacer()
                Text(track.duration > 0 ? Self.clock(track.duration) : "--:--")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private var lyricsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let source = model.lyricsSourceName {
                Text(String(format: loc("Words from %@"), source))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.bottom, 20)
            }
            if let lyrics = model.lyrics {
                timedLyrics(lyrics)
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
        .clipped()
    }

    private func timedLyrics(_ lyrics: Lyrics) -> some View {
        let current = model.lyricLine ?? 0
        return VStack(alignment: .leading, spacing: 25) {
            ForEach(-2...3, id: \.self) { offset in
                let index = current + offset
                if lyrics.lines.indices.contains(index) {
                    let line = lyrics.lines[index]
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
                                    Yun.Palette.accent.opacity(
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
                        lyricLine(
                            line.isInterlude ? Self.interludeMark : line.text,
                            offset: offset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: model.lyricLine)
    }

    @ViewBuilder
    private func lyricLine(_ text: String, offset: Int) -> some View {
        if offset == 0 {
            CompositedLyricSurface(model: model, text: text, style: .stage)
                .contentTransition(.opacity)
        } else {
            Text(text)
                .font(.system(size: offset < 0 ? 23 : 26, weight: .semibold))
                .foregroundStyle(.white.opacity(Self.lyricOpacity(for: offset)))
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
                .blur(radius: abs(offset) == 2 ? 1.2 : 0)
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

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
