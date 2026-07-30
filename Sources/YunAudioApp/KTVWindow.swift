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
            controller.window?.contentView = NSHostingView(rootView: KTVStage(model: model))
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
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: KTVStage(model: model))
        window.contentView?.setAccessibilityIdentifier("YunAudioKTVWindow")
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("YunAudioKTVWindow")
        window.center()
        return NSWindowController(window: window)
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
                stageBackground(size: proxy.size)

                if let track = model.nowPlaying {
                    HStack(alignment: .center, spacing: max(36, proxy.size.width * 0.055)) {
                        trackColumn(
                            track,
                            width: min(360, max(220, proxy.size.width * 0.31)))
                        lyricsColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, max(32, proxy.size.width * 0.055))
                    .padding(.vertical, max(34, proxy.size.height * 0.07))
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
                .padding(Yun.Space.lg)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color.black)
        .clipShape(.rect(cornerRadius: isRendering ? 18 : 0))
        .focusEffectDisabled()
        .accessibilityIdentifier("YunAudioKTVWindow")
    }

    @ViewBuilder
    private func stageBackground(size: CGSize) -> some View {
        if let track = model.nowPlaying {
            let phase = (model.lyricLine ?? 0) % 4
            SongArtwork(url: track.artworkURL, title: track.title, contentMode: .fill)
                .frame(width: size.width, height: size.height)
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

    private func trackColumn(_ track: NowPlaying.Track, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            SongArtwork(url: track.artworkURL, title: track.title, contentMode: .fit)
                .frame(width: width, height: width)
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
                    lyricLine(lyrics.lines[index].text, offset: offset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: model.lyricLine)
    }

    @ViewBuilder
    private func lyricLine(_ text: String, offset: Int) -> some View {
        if offset == 0 {
            ZStack(alignment: .leading) {
                Text(text)
                    .foregroundStyle(.white.opacity(0.62))
                    .contentTransition(.opacity)
                Text(text)
                    .foregroundStyle(.white)
                    .textRenderer(
                        SequentialTextFillRenderer(progress: model.lyricProgress)
                    )
                    .contentTransition(.opacity)
            }
            .font(.system(size: 34, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: model.lyricProgress)
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
