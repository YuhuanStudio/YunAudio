import CoreGraphics
import Foundation
import ImageIO

/// Reads one pixel out of an encoded image.
///
/// Both verification harnesses need this and both had their own copy: the
/// renderer to check its own pipeline is not altering colour, the window
/// capture to check a shot actually came out in the appearance it claims. Two
/// copies of twenty lines of CGContext arithmetic is two chances to get the
/// row-flip wrong in only one of them.
enum PixelProbe {
    /// Counts pixels matching a colour predicate inside a normalised,
    /// top-left-origin rectangle.
    ///
    /// `sample` redraws the image into a one-pixel context, which is exactly
    /// right for an appearance probe and catastrophically expensive for asking
    /// whether a whole chart contains ink. Decode once for content assertions.
    static func count(
        _ png: Data, in normalisedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        where predicate: (UInt8, UInt8, UInt8) -> Bool
    ) -> Int? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = bytes.withUnsafeMutableBytes({ raw in
                CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            })
        else { return nil }

        // Make memory row zero the visual top, matching the coordinates used by
        // the capture checks and by a person looking at the PNG.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x0 = max(0, min(width, Int((normalisedRect.minX * CGFloat(width)).rounded(.down))))
        let x1 = max(0, min(width, Int((normalisedRect.maxX * CGFloat(width)).rounded(.up))))
        let y0 = max(
            0, min(height, Int((normalisedRect.minY * CGFloat(height)).rounded(.down))))
        let y1 = max(0, min(height, Int((normalisedRect.maxY * CGFloat(height)).rounded(.up))))
        var count = 0
        for y in y0..<y1 {
            var offset = (y * width + x0) * 4
            for _ in x0..<x1 {
                if predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2]) {
                    count += 1
                }
                offset += 4
            }
        }
        return count
    }

    /// - Parameters:
    ///   - png: An encoded image.
    ///   - point: In image pixels, top-left origin.
    /// - Returns: The sampled colour, or nil when the image cannot be decoded.
    static func sample(_ png: Data, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return sample(image, at: point)
    }

    static func sample(
        _ image: CGImage, at point: CGPoint
    ) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = bytes.withUnsafeMutableBytes({ raw in
                CGContext(
                    data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            })
        else { return nil }
        // Draw the whole image offset so the wanted pixel lands in the single
        // pixel this context has. CoreGraphics counts rows from the bottom, so
        // the y offset is measured from the far edge.
        context.draw(
            image,
            in: CGRect(
                x: -point.x, y: -(CGFloat(image.height) - point.y - 1),
                width: CGFloat(image.width), height: CGFloat(image.height)))
        return (bytes[0], bytes[1], bytes[2])
    }
}
