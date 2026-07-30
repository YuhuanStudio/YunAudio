import AppKit
import CoreText
import QuartzCore
import SwiftUI
import YunDesign
import YunAudioEngine

/// The two lyric presentations share one compositor boundary.
///
/// The legacy renderer is deliberately retained as a benchmark control. Its
/// ten-hertz Observation dependency is never evaluated in production or in the
/// static compositor control.
struct CompositedLyricSurface: View {
    enum Style {
        case inspector
        /// The stage, at the size the stage worked out for the space it has.
        /// Fixed at 34 points, it stayed 34 on a wall-sized display and on a
        /// window barely taller than a line — and the lines around it scaled
        /// while it did not, so the one being sung came out smaller than its
        /// neighbours. See `KTVLyricMetrics`.
        case stage(CGFloat)

        var pointSize: CGFloat {
            switch self {
            case .inspector: 27
            case let .stage(size): size
            }
        }

        @MainActor var appKitFont: NSFont {
            switch self {
            case .inspector:
                NSFont.systemFont(ofSize: pointSize, weight: .semibold)
            case .stage:
                NSFont.systemFont(ofSize: pointSize, weight: .bold)
            }
        }

        @MainActor var swiftUIFont: Font {
            switch self {
            case .inspector:
                .system(size: pointSize, weight: .semibold)
            case .stage:
                .system(size: pointSize, weight: .bold)
            }
        }

        @MainActor var baseColour: NSColor {
            switch self {
            case .inspector:
                NSColor(Yun.Palette.textMuted)
            case .stage:
                NSColor.white.withAlphaComponent(0.62)
            }
        }

        @MainActor var fillColour: NSColor {
            switch self {
            case .inspector:
                NSColor(Yun.Palette.accent)
            case .stage:
                NSColor.white
            }
        }

        @MainActor var baseStyle: Color {
            switch self {
            case .inspector:
                Yun.Palette.textMuted
            case .stage:
                .white.opacity(0.62)
            }
        }

        @MainActor var fillStyle: Color {
            switch self {
            case .inspector:
                Yun.Palette.accent
            case .stage:
                .white
            }
        }
    }

    let model: RouterModel
    let text: String
    let style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let isOffscreenRender =
        ProcessInfo.processInfo.environment["YUNAUDIO_RENDER"] != nil

    var body: some View {
        let _ = BodyCount.tick("LyricFillSurface")
        let variant = YunUIBenchmarkConfiguration.process.effectiveVariant
        Group {
            if Self.isOffscreenRender {
                // ImageRenderer cannot rasterise an NSViewRepresentable: it
                // substitutes a yellow prohibition sign. Keep the standard
                // colour/layout render meaningful with a single static SwiftUI
                // frame. Real windows, real screenshots and production never
                // take this branch.
                swiftUISurface(
                    progress: model.lyricPlaybackAnchor?.progress(
                        at: Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                    ) ?? 0,
                    animates: false)
            } else if variant == .lyricFillLegacy {
                swiftUISurface(progress: model.lyricProgress, animates: true)
            } else {
                CompositedLyricFill(
                    text: text,
                    anchor: variant == .lyricFillStatic ? nil : model.lyricPlaybackAnchor,
                    font: style.appKitFont,
                    baseColour: style.baseColour,
                    fillColour: style.fillColour,
                    reduceMotion: reduceMotion,
                    frozenProgress: variant == .lyricFillStatic ? 0.5 : nil,
                    // The line being sung, so its own word times reach the
                    // layer. Absent, the fill keeps the linear animation.
                    syllables: model.currentLyricSyllables
                )
            }
        }
        .font(style.swiftUIFont)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }

    private func swiftUISurface(progress: Double, animates: Bool) -> some View {
        ZStack(alignment: .leading) {
            Text(text)
                .foregroundStyle(style.baseStyle)
            Text(text)
                .foregroundStyle(style.fillStyle)
                .textRenderer(SequentialTextFillRenderer(progress: progress))
        }
        .animation(
            reduceMotion || !animates ? nil : .linear(duration: 0.1),
            value: progress)
    }
}

/// A lyric whose per-frame sweep stays in Core Animation.
///
/// SwiftUI lays out this leaf only when the words, width or sparse playback
/// anchor change. CoreText draws the two text colours once; line-sized mask
/// layers then reveal the bright copy in reading order without publishing an
/// animation frame through Observation.
struct CompositedLyricFill: NSViewRepresentable {
    let text: String
    let anchor: LyricPlaybackAnchor?
    let font: NSFont
    let baseColour: NSColor
    let fillColour: NSColor
    let reduceMotion: Bool
    var frozenProgress: Double?

    func makeNSView(context: Context) -> CompositedLyricView {
        CompositedLyricView()
    }

    /// Word times for this line, when the file carried them.
    var syllables: [Lyrics.Line.Syllable] = []

    func updateNSView(_ view: CompositedLyricView, context: Context) {
        view.configure(
            text: text,
            font: font,
            baseColour: baseColour,
            fillColour: fillColour,
            anchor: anchor,
            reduceMotion: reduceMotion,
            frozenProgress: frozenProgress,
            syllables: syllables)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CompositedLyricView,
        context: Context
    ) -> CGSize? {
        let width = max(1, proposal.width ?? nsView.preferredMaximumWidth)
        return nsView.sizeThatFits(width: width)
    }
}

/// CoreText's geometry for one wrapped lyric.
struct CompositedLyricLayout {
    struct Row: Equatable {
        let rect: CGRect
        let startsOnRight: Bool
        let startProgress: Double
        let endProgress: Double
    }

    let size: CGSize
    let rows: [Row]
    fileprivate let frame: CTFrame

    static func make(text: String, font: NSFont, width: CGFloat) -> Self {
        let boundedWidth = max(1, width.isFinite ? width : 1)
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):
                    true,
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: boundedWidth, height: .greatestFiniteMagnitude),
            nil)
        let height = max(1, ceil(suggested.height))
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: boundedWidth, height: height),
            transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !origins.isEmpty {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        }

        struct MeasuredRow {
            let rect: CGRect
            let width: Double
            let startsOnRight: Bool
        }
        let measured = zip(lines, origins).map { line, origin in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = max(
                0,
                CGFloat(
                    CTLineGetTypographicBounds(
                        line,
                        &ascent,
                        &descent,
                        &leading)))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            let startsOnRight =
                runs.first(where: { CTRunGetGlyphCount($0) > 0 })
                .map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
            return MeasuredRow(
                rect: CGRect(
                    x: origin.x,
                    y: height - origin.y - ascent - 1,
                    width: width,
                    height: max(1, ascent + descent + leading + 2)),
                width: Double(width),
                startsOnRight: startsOnRight)
        }
        let totalWidth = measured.reduce(0) { $0 + $1.width }
        var consumed = 0.0
        let rows = measured.map { measured -> Row in
            let start = totalWidth > 0 ? consumed / totalWidth : 0
            consumed += measured.width
            let end = totalWidth > 0 ? consumed / totalWidth : 1
            return Row(
                rect: measured.rect,
                startsOnRight: measured.startsOnRight,
                startProgress: start,
                endProgress: end)
        }
        return Self(
            size: CGSize(width: boundedWidth, height: height),
            rows: rows,
            frame: frame)
    }
}

/// Timing for one line-sized compositor mask.
struct CompositedLyricTiming: Equatable {
    let initialScale: Double
    let delay: Double
    let duration: Double

    static func rows(
        layout: CompositedLyricLayout,
        progress: Double,
        remainingDuration: Double
    ) -> [Self] {
        let progress = max(0, min(1, progress.isFinite ? progress : 0))
        let remainingDuration =
            max(0, remainingDuration.isFinite ? remainingDuration : 0)
        let remainingProgress = max(0, 1 - progress)
        return layout.rows.map { row in
            let span = max(0, row.endProgress - row.startProgress)
            let initial =
                span > 0
                ? max(0, min(1, (progress - row.startProgress) / span))
                : 1
            guard remainingProgress > 0, remainingDuration > 0, initial < 1 else {
                return Self(initialScale: initial, delay: 0, duration: 0)
            }
            let firstProgress = max(progress, row.startProgress)
            let delay =
                (firstProgress - progress) / remainingProgress * remainingDuration
            let duration =
                (row.endProgress - firstProgress) / remainingProgress * remainingDuration
            return Self(
                initialScale: initial,
                delay: max(0, delay),
                duration: max(0, duration))
        }
    }
}

/// AppKit host retained by SwiftUI while Core Animation advances the sweep.
final class CompositedLyricView: NSView {
    let preferredMaximumWidth: CGFloat = 520

    private let baseLayer = CoreTextBackingLayer()
    private let fillLayer = CoreTextBackingLayer()
    private let revealLayer = CALayer()
    private var revealRows: [CALayer] = []
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 27, weight: .semibold)
    private var baseColour = NSColor.secondaryLabelColor
    private var fillColour = NSColor.controlAccentColor
    private var anchor: LyricPlaybackAnchor?
    private var reduceMotion = false
    private var frozenProgress: Double?
    private var configuredWidth: CGFloat = 0
    private var lyricLayout: CompositedLyricLayout?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        sizeThatFits(width: preferredMaximumWidth)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        root.addSublayer(baseLayer)
        root.addSublayer(fillLayer)
        fillLayer.mask = revealLayer
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        text: String,
        font: NSFont,
        baseColour: NSColor,
        fillColour: NSColor,
        anchor: LyricPlaybackAnchor?,
        reduceMotion: Bool,
        frozenProgress: Double?,
        syllables: [Lyrics.Line.Syllable] = []
    ) {
        self.syllables = syllables
        let needsTextLayout =
            self.text != text
            || self.font != font
            || self.baseColour != baseColour
            || self.fillColour != fillColour
        let needsTimeline =
            self.anchor != anchor
            || self.reduceMotion != reduceMotion
            || self.frozenProgress != frozenProgress
        self.text = text
        self.font = font
        self.baseColour = baseColour
        self.fillColour = fillColour
        self.anchor = anchor
        self.reduceMotion = reduceMotion
        self.frozenProgress = frozenProgress
        setAccessibilityValue(text)
        if needsTextLayout {
            configuredWidth = 0
            invalidateIntrinsicContentSize()
            needsLayout = true
        } else if needsTimeline {
            applyTimeline()
        }
    }

    func sizeThatFits(width: CGFloat) -> CGSize {
        CompositedLyricLayout.make(text: text, font: font, width: width).size
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        guard configuredWidth != width || lyricLayout == nil else { return }
        configuredWidth = width
        let layout = CompositedLyricLayout.make(text: text, font: font, width: width)
        lyricLayout = layout
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = CGRect(origin: .zero, size: layout.size)
        fillLayer.frame = baseLayer.frame
        revealLayer.frame = baseLayer.bounds
        baseLayer.configure(frame: layout.frame, colour: baseColour)
        fillLayer.configure(frame: layout.frame, colour: fillColour)
        rebuildRevealRows(for: layout)
        CATransaction.commit()
        applyTimeline()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        baseLayer.contentsScale = scale
        fillLayer.contentsScale = scale
        baseLayer.setNeedsDisplay()
        fillLayer.setNeedsDisplay()
    }

    /// Current compositor value, used by the benchmark to prove the layer tree
    /// really advances while SwiftUI's model stays unchanged.
    func presentationProgress() -> Double? {
        guard let layout = lyricLayout, !layout.rows.isEmpty else { return nil }
        var filled = 0.0
        for (index, row) in layout.rows.enumerated() {
            guard revealRows.indices.contains(index) else { continue }
            guard let layer = revealRows[index].presentation() else { return nil }
            let scale =
                (layer.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue
                ?? 0
            filled += max(0, min(1, scale)) * (row.endProgress - row.startProgress)
        }
        return max(0, min(1, filled))
    }

    private func rebuildRevealRows(for layout: CompositedLyricLayout) {
        revealRows.forEach { $0.removeFromSuperlayer() }
        revealRows = layout.rows.map { row in
            let layer = CALayer()
            layer.backgroundColor = NSColor.white.cgColor
            layer.anchorPoint = CGPoint(x: row.startsOnRight ? 1 : 0, y: 0.5)
            layer.bounds = CGRect(origin: .zero, size: row.rect.size)
            layer.position = CGPoint(
                x: row.startsOnRight ? row.rect.maxX : row.rect.minX,
                y: row.rect.midY)
            revealLayer.addSublayer(layer)
            return layer
        }
    }

    /// Word times for the line being drawn, when the file carried them.
    private var syllables: [Lyrics.Line.Syllable] = []

    private func applyTimeline() {
        guard let layout = lyricLayout else { return }
        let uptime = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let progress: Double
        let remainingDuration: Double
        let shouldAnimate: Bool
        if let frozenProgress {
            progress = frozenProgress
            remainingDuration = 0
            shouldAnimate = false
        } else if let anchor {
            progress = anchor.progress(at: uptime)
            remainingDuration = max(0, anchor.lineEnd - anchor.position(at: uptime))
            shouldAnimate = anchor.isPlaying && !reduceMotion
        } else {
            progress = 0
            remainingDuration = 0
            shouldAnimate = false
        }
        let timings = CompositedLyricTiming.rows(
            layout: layout,
            progress: progress,
            remainingDuration: shouldAnimate ? remainingDuration : 0)
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, rowLayer) in revealRows.enumerated() {
            rowLayer.removeAllAnimations()
            guard timings.indices.contains(index) else { continue }
            let timing = timings[index]
            if timing.duration == 0 {
                rowLayer.setValue(timing.initialScale, forKeyPath: "transform.scale.x")
                continue
            }
            rowLayer.setValue(1.0, forKeyPath: "transform.scale.x")
            // The shape the words describe, where the file gave one. The whole
            // line's curve is handed over at once and the animation is started
            // in the past by however much of the line has already been sung, so
            // Core Animation walks the same path it would have walked from the
            // beginning — rather than a straight line fitted to what remains.
            if shouldAnimate, !syllables.isEmpty, let anchor,
                let curve = CompositedLyricKeyFrames.fill(
                    row: (layout.rows[index].startProgress,
                        layout.rows[index].endProgress),
                    syllables: syllables,
                    line: (anchor.lineStart, anchor.lineEnd),
                    text: text)
            {
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.x")
                animation.values = curve.values
                animation.keyTimes = curve.keyTimes.map { NSNumber(value: $0) }
                animation.duration = max(0.001, anchor.lineEnd - anchor.lineStart)
                animation.beginTime =
                    now - max(0, anchor.position(at: uptime) - anchor.lineStart)
                animation.calculationMode = .linear
                animation.fillMode = .backwards
                animation.isRemovedOnCompletion = true
                rowLayer.add(animation, forKey: "lyric-fill")
                continue
            }
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = timing.initialScale
            animation.toValue = 1.0
            animation.beginTime = now + timing.delay
            animation.duration = timing.duration
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = true
            rowLayer.add(animation, forKey: "lyric-fill")
        }
        CATransaction.commit()
    }
}

private final class CoreTextBackingLayer: CALayer {
    private var textFrame: CTFrame?
    private var colour = NSColor.labelColor

    override init() {
        super.init()
        drawsAsynchronously = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) {
        if let layer = layer as? CoreTextBackingLayer {
            textFrame = layer.textFrame
            colour = layer.colour
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(frame: CTFrame, colour: NSColor) {
        textFrame = frame
        self.colour = colour
        setNeedsDisplay()
    }

    override func draw(in context: CGContext) {
        guard let textFrame else { return }
        context.saveGState()
        context.setFillColor(colour.cgColor)
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(textFrame, context)
        context.restoreGState()
    }
}

/// Key frames that make a row's fill follow the words rather than the clock.
///
/// A row is filled by animating `transform.scale.x` from where it starts to
/// one. With a single linear animation that fill crosses the row evenly, which
/// is right only if every syllable in it lasts the same time — so the highlight
/// runs late through a held note and early through a quick one, and a singer
/// reading it is pulled off the beat.
///
/// Core Animation can be handed the shape instead: the same start and end, with
/// the sung fraction at each syllable boundary in between. The render server
/// still does all the work per frame; the difference is which curve it walks.
enum CompositedLyricKeyFrames {

    /// - Parameters:
    ///   - row: Where this row sits in the line, from 0 to 1.
    ///   - syllables: Word times for the whole line, in order.
    ///   - line: When the line begins and ends, in the track's own seconds.
    /// - Returns: Times from 0 to 1 across the animation, with the row's scale
    ///   at each, or nil when the line carries no word times and the caller
    ///   should keep its linear animation.
    static func fill(
        row: (start: Double, end: Double),
        syllables: [Lyrics.Line.Syllable],
        line: (start: Double, end: Double),
        text: String
    ) -> (keyTimes: [Double], values: [Double])? {
        guard !syllables.isEmpty, line.end > line.start, !text.isEmpty else {
            return nil
        }
        let span = row.end - row.start
        guard span > 0 else { return nil }

        let sample = Lyrics.Line(
            time: line.start, text: text, syllables: syllables)
        var keyTimes: [Double] = []
        var values: [Double] = []

        func add(_ seconds: Double) {
            let time = (seconds - line.start) / (line.end - line.start)
            guard time >= 0, time <= 1 else { return }
            let progress = sample.progress(at: seconds, lineEnd: line.end) ?? 0
            let scale = max(0, min(1, (progress - row.start) / span))
            // Core Animation requires key times to increase. Two syllables
            // stamped at the same moment — which files do — would otherwise
            // produce an animation it rejects outright, and the row would not
            // fill at all.
            if let last = keyTimes.last, time <= last { return }
            keyTimes.append(time)
            values.append(scale)
        }

        add(line.start)
        for syllable in syllables { add(syllable.time) }
        add(line.end)

        guard keyTimes.count >= 2 else { return nil }
        return (keyTimes, values)
    }
}
