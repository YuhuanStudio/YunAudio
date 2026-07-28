import SwiftUI
import YunAudioEngine
import YunDesign

/// Draws what a correction actually does, across the audible range.
///
/// Read off the response of the coefficients rather than off the filter
/// definitions, which is not a detail. A picture built from "there is a 6 dB
/// peak at 1 kHz" stays right for as long as somebody keeps saying so; a
/// picture built from the arithmetic goes wrong the moment the arithmetic does,
/// which is the only time anybody needs to be told.
struct EQCurveView: View {
    let curve: ParametricEQ
    /// The rate the curve is evaluated at. Not the route's, deliberately: this
    /// is a drawing, and redrawing it every time a device changes rate would
    /// show motion that is not there.
    var sampleRate: Double = 48000

    /// Half the range of a typical correction, so the shape is legible rather
    /// than a flat line with one spike.
    private let span: Float = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                // Unity, so a curve can be read as "above" or "below" without
                // measuring against the frame.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height / 2))
                    path.addLine(to: CGPoint(x: width, y: height / 2))
                }
                .stroke(Yun.Palette.border, lineWidth: 1)

                Path { path in
                    for step in 0...120 {
                        let fraction = Float(step) / 120
                        // Log-spaced: 20 Hz to 20 kHz, which is how hearing is
                        // spaced and how every correction is published.
                        let hertz = 20 * pow(1000, fraction)
                        let decibels = curve.response(atHertz: hertz, sampleRate: sampleRate)
                        let y = height / 2 - CGFloat(max(-span, min(span, decibels)) / span)
                            * height / 2
                        let point = CGPoint(x: CGFloat(fraction) * width, y: y)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(Yun.Palette.accent, style: .init(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}
