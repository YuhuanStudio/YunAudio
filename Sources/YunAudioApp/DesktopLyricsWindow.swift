import AppKit
import SwiftUI
import YunAudioEngine
import YunDesign

/// The line being sung, over everything, without a window to switch to.
///
/// A stage you have to bring forward is a stage you look at instead of doing
/// whatever you opened the computer for. This is the same words with no
/// application around them: it floats above full-screen apps, never takes key
/// focus, and passes clicks through except on itself, so typing continues into
/// whatever was already in front.
@MainActor
enum DesktopLyricsWindow {
    private static var controller: NSWindowController?

    static var isVisible: Bool { controller?.window?.isVisible == true }

    static func toggle(model: RouterModel) {
        if isVisible {
            close()
        } else {
            open(model: model)
        }
    }

    @discardableResult
    static func open(model: RouterModel) -> Bool {
        let controller = controller ?? makeController(model: model)
        self.controller = controller
        controller.window?.orderFrontRegardless()
        model.showsDesktopLyrics = true
        return controller.window?.isVisible == true
    }

    static func close() {
        controller?.window?.orderOut(nil)
    }

    private static func makeController(model: RouterModel) -> NSWindowController {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Above full-screen applications and every ordinary window, and present
        // on whichever space the user moves to — a lyric that disappears when
        // somebody switches desktop is a lyric they stop relying on.
        window.level = .statusBar
        window.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.contentViewController = NSHostingController(
            rootView: DesktopLyrics(model: model))
        window.setFrameAutosaveName("YunAudioDesktopLyrics")
        if window.frame.origin == .zero { position(window) }
        return NSWindowController(window: window)
    }

    /// Centred along the bottom of the screen the pointer is on, above the Dock.
    private static func position(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        window.setFrameOrigin(
            CGPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.minY + 48))
    }
}

/// What the floating window draws.
private struct DesktopLyrics: View {
    @Bindable var model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("DesktopLyrics")
        VStack(spacing: 6) {
            if let line = currentLine {
                // The same compositor as the stage, so the fill follows the
                // words here too. It reads the line's own timings from the
                // model rather than being handed them.
                CompositedLyricSurface(
                    model: model, text: line.text, style: .stage(30))
                .contentTransition(.opacity)
                if model.showsRomanisation, let latin = LyricRomanisation.of(line.text) {
                    Text(latin)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Yun.Palette.accent.opacity(0.86))
                }
                if let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
            } else {
                Text(model.nowPlaying?.title ?? loc("Nothing is playing"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(.horizontal, Yun.Space.xl)
        .padding(.vertical, Yun.Space.lg)
        .frame(maxWidth: .infinity)
        // Its own backdrop rather than the desktop's: white words on a white
        // wallpaper are not words. Dark enough to read against anything, soft
        // enough not to be a box sitting on the screen.
        .background(.black.opacity(0.52), in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.28), value: model.lyricLine)
        .accessibilityIdentifier("YunAudioDesktopLyrics")
    }

    private var currentLine: Lyrics.Line? {
        guard let lyrics = model.lyrics, let index = model.lyricLine,
            lyrics.lines.indices.contains(index)
        else { return nil }
        return lyrics.lines[index]
    }
}
