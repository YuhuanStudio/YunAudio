import AppKit
import QuartzCore
import Testing

@testable import YunAudioApp

@MainActor
@Suite("Composited lyric fill")
struct CompositedLyricFillTests {
    @Test("playback anchors hold pauses and clamp seeks")
    func anchorArithmetic() {
        let playing = LyricPlaybackAnchor(
            lineIndex: 2,
            lineStart: 10,
            lineEnd: 14,
            position: 11,
            trueAt: 100,
            isPlaying: true,
            revision: 1)
        #expect(playing.position(at: 101.5) == 12.5)
        #expect(playing.progress(at: 101.5) == 0.625)
        #expect(playing.progress(at: 90) == 0.25)
        #expect(playing.progress(at: 200) == 1)

        let paused = LyricPlaybackAnchor(
            lineIndex: 2,
            lineStart: 10,
            lineEnd: 14,
            position: 11.75,
            trueAt: 100,
            isPlaying: false,
            revision: 2)
        #expect(paused.position(at: 200) == 11.75)
        #expect(paused.progress(at: 200) == 0.4375)

        let beforeFirstLine = LyricPlaybackAnchor(
            lineIndex: nil,
            lineStart: 0,
            lineEnd: 0,
            position: 1,
            trueAt: 100,
            isPlaying: true,
            revision: 3)
        #expect(beforeFirstLine.progress(at: 200) == 0)
    }

    @Test("CoreText keeps Chinese production credits, wrapping and mixed scripts")
    func coreTextLayoutKeepsRealLyrics() {
        let text = "作詞：Wonderful／作曲：阿沁 Real Band\n年少心動的雨季"
        let layout = CompositedLyricLayout.make(
            text: text,
            font: .systemFont(ofSize: 27, weight: .semibold),
            width: 190)

        #expect(layout.rows.count >= 3)
        #expect(layout.size.width == 190)
        #expect(layout.size.height > 54)
        #expect(layout.rows.first?.startProgress == 0)
        #expect(abs((layout.rows.last?.endProgress ?? 0) - 1) < 0.000_001)
        for pair in zip(layout.rows, layout.rows.dropFirst()) {
            #expect(pair.0.endProgress <= pair.1.startProgress + 0.000_001)
        }
    }

    @Test("right-to-left rows reveal from their reading edge")
    func rightToLeftLayout() {
        let layout = CompositedLyricLayout.make(
            text: "مرحبا بالعالم",
            font: .systemFont(ofSize: 30, weight: .semibold),
            width: 420)

        #expect(layout.rows.count == 1)
        #expect(layout.rows[0].startsOnRight)
    }

    @Test("wrapped rows divide one linear song interval exactly")
    func rowTiming() {
        let layout = CompositedLyricLayout.make(
            text: "first visual row then a second visual row then a third",
            font: .systemFont(ofSize: 27, weight: .semibold),
            width: 180)
        let timings = CompositedLyricTiming.rows(
            layout: layout,
            progress: 0.23,
            remainingDuration: 3.7)

        #expect(timings.count == layout.rows.count)
        #expect(timings.allSatisfy { 0...1 ~= $0.initialScale })
        #expect(timings.allSatisfy { $0.delay >= 0 && $0.duration >= 0 })
        let final =
            zip(layout.rows, timings)
            .filter { $0.0.endProgress > 0.23 }
            .map { $0.1.delay + $0.1.duration }
            .max() ?? 0
        #expect(abs(final - 3.7) < 0.000_001)
    }

    @Test("the AppKit leaf exposes the full lyric as one static text element")
    func accessibility() {
        let view = CompositedLyricView()
        view.configure(
            text: "作詞：Wonderful",
            font: .systemFont(ofSize: 27, weight: .semibold),
            baseColour: .secondaryLabelColor,
            fillColour: .controlAccentColor,
            anchor: nil,
            reduceMotion: false,
            frozenProgress: nil)

        #expect(view.accessibilityRole() == .staticText)
        #expect(view.accessibilityValue() as? String == "作詞：Wonderful")
    }

    @Test("the presentation layer advances without another model value")
    func presentationLayerMoves() async throws {
        _ = NSApplication.shared
        let view = CompositedLyricView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 80))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        view.configure(
            text: "The presentation layer is the animation",
            font: .systemFont(ofSize: 27, weight: .semibold),
            baseColour: .secondaryLabelColor,
            fillColour: .controlAccentColor,
            anchor: LyricPlaybackAnchor(
                lineIndex: 0,
                lineStart: 0,
                lineEnd: 2,
                position: 0.2,
                trueAt: now,
                isPlaying: true,
                revision: 1),
            reduceMotion: false,
            frozenProgress: nil)
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        try await Task.sleep(for: .milliseconds(70))
        let before = try #require(view.presentationProgress())
        try await Task.sleep(for: .milliseconds(180))
        let after = try #require(view.presentationProgress())
        print("lyric presentation progress \(before) → \(after)")

        #expect(after > before + 0.04)
        #expect(after < 1)
    }

    @Test("production call sites never observe the ten-hertz legacy progress")
    func productionObservationBoundary() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let singing = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/SingingPanel.swift"),
            encoding: .utf8)
        let ktv = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/KTVWindow.swift"),
            encoding: .utf8)
        let compositor = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/CompositedLyricFill.swift"),
            encoding: .utf8)

        #expect(!singing.contains("model.lyricProgress"))
        #expect(!ktv.contains("model.lyricProgress"))
        #expect(compositor.ranges(of: "model.lyricProgress").count == 1)
        #expect(compositor.contains("variant == .lyricFillLegacy"))
        #expect(compositor.contains("variant == .lyricFillStatic ? 0.5 : nil"))
        #expect(compositor.contains("model.lyricPlaybackAnchor"))
    }
}
