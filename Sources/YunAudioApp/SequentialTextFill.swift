import SwiftUI

/// Lights wrapped text in reading order instead of cutting every visual line
/// with the same vertical edge.
///
/// A rectangular mask is correct for one line. Once the lyric wraps, however,
/// that mask advances through every row at once. The renderer receives the
/// actual line fragments from SwiftUI, spends the available progress on the
/// first line, and only then starts the next.
struct SequentialTextFillRenderer: TextRenderer {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var totalWidth: CGFloat = 0
        for line in layout {
            totalWidth += max(0, line.typographicBounds.width)
        }
        var remaining =
            totalWidth * CGFloat(max(0, min(1, progress.isFinite ? progress : 0)))

        for line in layout where remaining > 0 {
            let bounds = line.typographicBounds.rect
            let lineWidth = max(0, line.typographicBounds.width)
            let width = min(lineWidth, remaining)
            let startsOnRight = line.first?.layoutDirection == .rightToLeft
            let x = startsOnRight ? bounds.maxX - width : bounds.minX
            let clip = CGRect(
                x: x,
                y: bounds.minY - 1,
                width: width,
                height: bounds.height + 2)
            var clipped = context
            clipped.clip(to: Path(clip))
            clipped.draw(line)
            remaining = max(0, remaining - lineWidth)
        }
    }
}

enum SequentialLineFill {
    /// Returns the visible width of each laid-out row for one overall progress.
    ///
    /// Kept independent of SwiftUI's renderer so the rule is numerically
    /// asserted without relying on pixels or a particular font.
    nonisolated static func widths(lineWidths: [Double], progress: Double) -> [Double] {
        let boundedWidths = lineWidths.map { max(0, $0.isFinite ? $0 : 0) }
        let total = boundedWidths.reduce(0, +)
        var remaining = total * max(0, min(1, progress.isFinite ? progress : 0))

        return boundedWidths.map { width in
            let filled = min(width, remaining)
            remaining = max(0, remaining - width)
            return filled
        }
    }
}
