import AppKit
import CoreImage
import SwiftUI

/// The blurred cover behind the words, blurred once and drifted on the layer.
///
/// Measured, because it did not look like the expensive thing. With the KTV
/// stage open the process spent 310–340 ms of processor time per five seconds
/// of playing; with the background's slow scale-and-offset removed and nothing
/// else changed, 145–152 ms. The drift was more than half the entire cost of
/// the stage — more than the words, the meters and the artwork together.
///
/// Nor was it the blur. Setting the radius to zero changed nothing (329–348
/// ms); removing the modifier altogether changed nothing (316–331 ms). A
/// full-window picture resampled sixty times a second is the cost, whatever is
/// drawn on it.
///
/// So the animation moves to where the lyric fill already went: a
/// `CABasicAnimation` on a layer's transform, interpolated by the render server
/// with no application frame behind it.
///
/// The blur is done here rather than in SwiftUI because SwiftUI's `.blur`
/// simply does not survive a nested `NSHostingView` — the first attempt at
/// this hosted the existing view and photographed a background with no blur on
/// it at all, sharp enough to read the bridle through the words. One
/// `CIGaussianBlur` over the decoded 256-point cover, once per song, is both
/// the honest way to get it and cheaper than asking for it every frame.
struct CompositedStageBackdrop: NSViewRepresentable {
    let url: URL?
    let isMoving: Bool

    /// How far the picture grows at the far end of the drift.
    static let scale: (from: CGFloat, to: CGFloat) = (1.16, 1.19)

    /// How far it travels, as a fraction of the window, at the far end.
    static let travel: (x: CGFloat, y: CGFloat) = (8, 5)

    /// One way across. Long, because this is a room the eye sits in for a whole
    /// song and anything quicker reads as a slideshow.
    static let duration: CFTimeInterval = 9

    /// Blur radius as a fraction of the cover's own width.
    ///
    /// Expressed against the source rather than the window: the store decodes
    /// covers to 256 points, and a radius in window points would be five times
    /// too small on the picture it is actually applied to.
    ///
    /// Arrived at by photographing it rather than by conversion: the ratio
    /// SwiftUI's fifty-two points worked out to came back as a flat wash with
    /// no cover visible at all, because `CIGaussianBlur` takes a far wider
    /// kernel for the same number. 0.014 — three and a half pixels on a
    /// 256-point cover — is the picture the stage had before.
    nonisolated static let blurFraction: CGFloat = 0.014

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.show(url)
        view.setDrifting(isMoving)
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.show(url)
        view.setDrifting(isMoving)
    }

    /// One layer, one picture, one animation.
    final class BackdropView: NSView {
        private var shown: URL??
        private var loading: Task<Void, Never>?
        private var isDrifting = false

        /// The picture lives on a sublayer, not on the view's own backing layer.
        ///
        /// A view's backing layer belongs to AppKit: it sets the frame from the
        /// view's, and it does that against its own idea of the anchor point.
        /// Moving that anchor to the middle — which a scale about the centre
        /// needs — leaves the two disagreeing, and the picture sits half a
        /// window off to one side. That is what the offset background was.
        /// A sublayer is mine: `CALayer` already anchors at its centre, so the
        /// transform means what it says and nothing re-lays it out behind me.
        let picture = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            picture.contentsGravity = .resizeAspectFill
            picture.masksToBounds = true
            layer?.addSublayer(picture)
        }

        required init?(coder: NSCoder) { nil }

        deinit { loading?.cancel() }

        /// Puts a song's cover up, blurred, without asking twice for the same
        /// one — `updateNSView` runs on every stage rebuild.
        func show(_ url: URL?) {
            guard shown != .some(url) else { return }
            shown = .some(url)
            loading?.cancel()
            guard let url else {
                picture.contents = nil
                return
            }
            loading = Task { [weak self] in
                guard let decoded = await SongArtworkResources.shared.value(for: url),
                    !Task.isCancelled
                else { return }
                let blurred = await Task.detached(priority: .utility) {
                    Self.blur(decoded.image)
                }.value
                guard !Task.isCancelled, let blurred else { return }
                self?.picture.contents = blurred
            }
        }

        func setDrifting(_ moving: Bool) {
            guard moving != isDrifting else { return }
            isDrifting = moving
            applyDrift()
        }

        override func layout() {
            super.layout()
            // Bounds and position rather than a frame: a layer carrying a
            // transform has no meaningful frame, and setting one applies the
            // transform to it twice.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.bounds = CGRect(origin: .zero, size: bounds.size)
            picture.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            let layer = picture
            // The drift is not rebuilt here. Layout runs on every frame of a
            // window drag, and rebuilding the animation resets it to its first
            // frame — which meant the background stood still for as long as
            // somebody was resizing, and then started its nine seconds again
            // from the beginning. The transform is a scale and a translation in
            // points, so it is the same animation at any size; only the
            // geometry above depends on the bounds.
            if layer.animation(forKey: "drift") == nil { applyDrift() }
        }

        private func applyDrift() {
            let layer = picture
            layer.removeAnimation(forKey: "drift")
            let resting = CATransform3DMakeScale(
                CompositedStageBackdrop.scale.from, CompositedStageBackdrop.scale.from, 1)
            guard isDrifting, bounds.width > 0 else {
                // Still, but still oversized: the scale is what keeps the
                // window covered while the picture moves inside it.
                layer.transform = resting
                return
            }
            let far = CATransform3DTranslate(
                CATransform3DMakeScale(
                    CompositedStageBackdrop.scale.to, CompositedStageBackdrop.scale.to, 1),
                CompositedStageBackdrop.travel.x, CompositedStageBackdrop.travel.y, 0)
            let drift = CABasicAnimation(keyPath: "transform")
            drift.fromValue = NSValue(caTransform3D: resting)
            drift.toValue = NSValue(caTransform3D: far)
            drift.duration = CompositedStageBackdrop.duration
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.isRemovedOnCompletion = false
            layer.transform = resting
            layer.add(drift, forKey: "drift")
        }

        /// One Gaussian, on a utility thread, once per song.
        nonisolated static func blur(_ image: CGImage) -> CGImage? {
            let input = CIImage(cgImage: image)
            // Clamped first, or the blur pulls transparency in from beyond the
            // edges and the stage gets a dark frame around the picture.
            guard
                let blurred = CIFilter(
                    name: "CIGaussianBlur",
                    parameters: [
                        kCIInputImageKey: input.clampedToExtent(),
                        kCIInputRadiusKey: CGFloat(image.width)
                            * CompositedStageBackdrop.blurFraction,
                    ])?.outputImage
            else { return nil }
            return CIContext(options: [.useSoftwareRenderer: false])
                .createCGImage(blurred, from: input.extent)
        }
    }
}
