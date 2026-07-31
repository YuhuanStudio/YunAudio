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
            // A minute-long line. The two-second fixture this replaces read
            // 1.0 → 1.0 every time the whole suite ran and passed whenever the
            // test ran alone: with 1067 tests in flight, more than the 1.6
            // seconds it had left could pass between configuring the view and
            // the first sample, so the sweep had already finished. The subject
            // here is whether the layer advances, not how quickly.
            anchor: LyricPlaybackAnchor(
                lineIndex: 0,
                lineStart: 0,
                lineEnd: Self.lineSeconds,
                position: 0,
                trueAt: now,
                isPlaying: true,
                revision: 1),
            reduceMotion: false,
            frozenProgress: nil)
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        try await Task.sleep(for: .milliseconds(70))
        let before = try #require(view.presentationProgress())
        let beforeAt = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        try await Task.sleep(for: .milliseconds(180))
        let after = try #require(view.presentationProgress())
        let afterAt = Double(DispatchTime.now().uptimeNanoseconds) / 1e9

        // Against the time that actually passed, not the time the sleep asked
        // for — under load it is the elapsed interval that moves, and an
        // assertion written against the requested interval measures the
        // scheduler rather than the compositor.
        let expected = (afterAt - beforeAt) / Self.lineSeconds
        print(
            "lyric presentation progress \(before) → \(after)"
                + " over \(afterAt - beforeAt) s, expected +\(expected)")

        #expect(
            after > before + expected * 0.5,
            "the compositor advanced \(after - before) where the anchor describes \(expected)")
        #expect(after < 1)
    }

    /// Long enough that a contended run cannot exhaust the sweep before it is
    /// sampled, short enough that 180 milliseconds of it is still measurable.
    private static let lineSeconds: Double = 60

    @Test("the sweep is lit through a soft edge, held to one width")
    @MainActor
    func revealRowsCarryTheFeather() throws {
        let view = CompositedLyricView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        let size: CGFloat = 27
        view.configure(
            text: "光穿過字，而不是切過字",
            font: .systemFont(ofSize: size, weight: .bold),
            baseColour: .white.withAlphaComponent(0.62),
            fillColour: .white,
            anchor: nil,
            reduceMotion: false,
            // Half way, so the mask is neither empty nor the whole row and the
            // edge is somewhere a reader would be looking.
            frozenProgress: 0.5)
        view.layoutSubtreeIfNeeded()

        let rows = view.revealRowsForCheck()
        #expect(!rows.isEmpty)
        let feather = LyricFillFeather.width(forPointSize: size)
        let columns = CGFloat(LyricFillFeather.columns(feather: feather))
        for row in rows {
            // A plain rectangle is what put a vertical line down the middle of
            // the glyph being sung; contents is how it stopped being one.
            #expect(row.contents != nil)
            // One column of the image stretches, so the fade stays this wide
            // at every point across the row rather than opening as it goes.
            #expect(abs(row.contentsCenter.width - 1 / columns) < 1e-6)
            #expect(row.contentsCenter.height == 1)
        }
        // Half of an eleven-point fade sits ahead of the boundary, so the mask
        // reaches past half the row rather than stopping short of it.
        let widest = rows.map(\.bounds.width).max() ?? 0
        #expect(widest > 0)
        #expect(feather == 11)
    }

    @Test("the syllable being sung is brighter than the ones already sung")
    @MainActor
    func theHighlightTravels() throws {
        _ = NSApplication.shared
        let view = CompositedLyricView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let size: CGFloat = 30
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        view.configure(
            text: "光走過的那一個字最亮",
            font: .systemFont(ofSize: size, weight: .bold),
            baseColour: .white.withAlphaComponent(0.62),
            fillColour: .white,
            anchor: LyricPlaybackAnchor(
                lineIndex: 0, lineStart: 0, lineEnd: 60, position: 0,
                trueAt: now, isPlaying: true, revision: 1),
            reduceMotion: false,
            frozenProgress: nil)
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let glow = view.glowForCheck()
        // A halo rather than a second colour, because a colour would have to be
        // chosen and this has to work over a blurred cover of any hue.
        #expect(glow.layer.shadowOpacity == 1)
        #expect(glow.layer.shadowOffset == .zero)
        #expect(glow.layer.shadowRadius == size * 0.2)
        #expect(glow.layer.mask != nil)
        // One window per row, and each one moving: a highlight that does not
        // travel is a smudge parked in the middle of a line.
        #expect(!glow.bands.isEmpty)
        for band in glow.bands {
            #expect(band.animation(forKey: "lyric-glow") != nil)
            // Narrow. Three feathers is about a character and a half — a
            // highlight on a syllable rather than on the whole line.
            #expect(band.bounds.width < view.bounds.width / 2)
        }
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

/// The pale block at the start of a wrapped line.
///
/// Reported twice. The first fix clipped the highlight card, on the theory that
/// the sweep's glow was spilling out of it — it was not outside the card at all.
/// The mask for a row that had not been reached was `feather / 2` points wide,
/// and the leading pixels of that mask are the bright end of the fade, so the
/// second visual row of a wrapped line carried a lit stub under a word nobody
/// had sung yet.
@Suite("a row nobody has reached shows nothing")
struct UnstartedLyricRowTests {

    @Test("the second row of a wrapped line is empty at the start of the first")
    @MainActor
    func wrappedRowStartsEmpty() throws {
        let view = CompositedLyricView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        let size: CGFloat = 27
        // Long enough at 300 points to wrap, and the reported line: the block
        // appeared under 的 at the head of the second row.
        view.configure(
            text: "我懷念那個你我深愛的你我真的好想你",
            font: .systemFont(ofSize: size, weight: .bold),
            baseColour: .white.withAlphaComponent(0.62),
            fillColour: .white,
            anchor: nil,
            reduceMotion: true,
            // Nothing sung yet: every row must be empty, including the first.
            frozenProgress: 0)
        view.layoutSubtreeIfNeeded()

        let rows = view.revealRowsForCheck()
        #expect(rows.count >= 2, "the fixture has to wrap for this to mean anything")
        for (index, row) in rows.enumerated() {
            #expect(row.bounds.width == 0, "row \(index) was \(row.bounds.width) wide")
        }
    }

    @Test("and a row still shows nothing when an earlier one is part way through")
    @MainActor
    func laterRowsStayEmpty() throws {
        let view = CompositedLyricView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        view.configure(
            text: "我懷念那個你我深愛的你我真的好想你",
            font: .systemFont(ofSize: 27, weight: .bold),
            baseColour: .white.withAlphaComponent(0.62),
            fillColour: .white,
            anchor: nil,
            reduceMotion: true,
            // A quarter through: inside the first row on a two-row wrap, so
            // every row after it has not been reached.
            frozenProgress: 0.25)
        view.layoutSubtreeIfNeeded()

        let rows = view.revealRowsForCheck()
        #expect(rows.count >= 2)
        #expect(rows[0].bounds.width > 0, "the row being sung has to be lit")
        for index in 1..<rows.count {
            #expect(rows[index].bounds.width == 0, "row \(index) leaked")
        }
    }
}

/// The switch, the sentence under it, and the reading beside them.
@Suite("what the sound model switch actually controls")
struct SoundModelReadoutTests {

    @Test("the reading is shown only when somebody asked for it")
    func readoutFollowsTheSwitch() {
        #expect(
            SoundModelUse.of(identifying: true, levelling: false, ducking: false)
                .showsReadout)
        // The reported contradiction: switch off, ducking on, reading on screen
        // above a sentence saying the switch controls the reading.
        #expect(
            !SoundModelUse.of(identifying: false, levelling: false, ducking: true)
                .showsReadout)
        #expect(
            !SoundModelUse.of(identifying: false, levelling: true, ducking: false)
                .showsReadout)
        #expect(
            !SoundModelUse.of(identifying: false, levelling: false, ducking: false)
                .showsReadout)
    }

    @Test("but the model is still loaded for whoever needed it")
    func loadingIsUnchanged() {
        // The reading going away must not take the model with it: levelling and
        // ducking act on its verdict whether or not anybody is watching.
        let forDucking = SoundModelUse.of(identifying: false, levelling: false, ducking: true)
        #expect(forDucking.isLoaded)
        #expect(!forDucking.showsReadout)
        #expect(forDucking == .forSomethingElse)
    }
}

/// The halo on a row nobody has reached.
///
/// The still branch has always refused to park one mid-line. The moving branch
/// set every row's halo to full opacity, so on a wrapped line a soft bright blob
/// sat at the leading edge of the second row, behind a character nobody had
/// sung. Reported three times, and the first two readings of it — the glow
/// escaping the card, the fill mask's half-feather — were different defects that
/// are also fixed.
@Suite("no halo on a row nobody has reached")
struct UnreachedRowHaloTests {

    @Test("the second row carries no light while the first is being sung")
    @MainActor
    func theHaloWaitsForItsRow() throws {
        let view = CompositedLyricView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        view.configure(
            text: "難道非要耗盡所有委屈才能學會不在乎",
            font: .systemFont(ofSize: 27, weight: .bold),
            baseColour: .white.withAlphaComponent(0.62),
            fillColour: .white,
            anchor: nil,
            reduceMotion: false,
            // Inside the first row of a wrap.
            frozenProgress: 0.2)
        view.layoutSubtreeIfNeeded()

        let rows = view.revealRowsForCheck()
        let halos = view.glowBandsForCheck()
        #expect(rows.count >= 2, "the fixture has to wrap")
        #expect(halos.count == rows.count)
        for index in 1..<halos.count {
            #expect(halos[index].opacity == 0, "row \(index) carried a halo")
        }
    }

    @Test("and none of them does before the line has started at all")
    @MainActor
    func nothingBeforeTheLine() throws {
        let view = CompositedLyricView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        view.configure(
            text: "難道非要耗盡所有委屈才能學會不在乎",
            font: .systemFont(ofSize: 27, weight: .bold),
            baseColour: .white.withAlphaComponent(0.62),
            fillColour: .white,
            anchor: nil,
            reduceMotion: false,
            frozenProgress: 0)
        view.layoutSubtreeIfNeeded()
        for (index, halo) in view.glowBandsForCheck().enumerated() {
            #expect(halo.opacity == 0, "row \(index) carried a halo at nought")
        }
    }
}
